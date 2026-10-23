import Foundation

/// One browser connected over WebSocket. Handles pairing, owns the capture
/// pipeline for that browser, applies flow control and forwards input.
/// Everything runs on the server queue.
final class ClientSession {
    let id: UUID
    private(set) var info: SessionInfo
    private(set) var hasGreeted = false

    private weak var server: StreamServer?
    private let socket: WebSocketConnection
    private let userAgent: String
    private var authenticated = false
    private var supportsH264 = false
    private var stopped = false

    private var pipeline: StreamPipeline?
    private var generation = 0
    private var input: InputController?

    // Flow control: at most `maxInFlight` frames sent but not yet drawn.
    private let maxInFlight = 3
    private var inFlight = 0
    private var lastAck = Date()
    private var needsKeyframe = true

    // Stats for the current one-second window.
    private var framesSent = 0
    private var bytesSent = 0
    private var rttSamples: [Double] = []

    init(server: StreamServer, socket: WebSocketConnection, address: String, userAgent: String) {
        self.server = server
        self.socket = socket
        self.userAgent = userAgent
        let id = UUID()
        self.id = id
        let defaults = server.config.defaults
        let platform = ClientPlatform.detect(userAgent: userAgent, touchPoints: 0)
        info = SessionInfo(
            id: id,
            name: "\(ClientPlatform.browserName(userAgent: userAgent)) on \(platform.label)",
            platform: platform,
            address: address,
            screen: ClientScreen(width: 1280, height: 800, scale: 1),
            params: defaults,
            activeCodec: defaults.codec
        )
    }

    func start() {
        socket.onText = { [weak self] text in self?.handle(text) }
        socket.onClose = { [weak self] in self?.teardown() }
        socket.start()
    }

    func stop() {
        socket.close()
    }

    func update(params: StreamParameters) {
        info.params = params
        if authenticated { startPipeline() }
        server?.publishSessions()
    }

    // MARK: Messages

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["t"] as? String else { return }

        switch type {
        case "hello":
            handleHello(message)
        case "ack":
            if let ts = message["ts"] as? Double {
                rttSamples.append(Date().timeIntervalSince1970 * 1000 - ts)
            }
            inFlight = max(0, inFlight - 1)
            lastAck = Date()
        case "keyframe":
            needsKeyframe = true
            pipeline?.requestKeyframe()
        case "resize":
            guard authenticated else { return }
            let screen = Self.screen(from: message, fallback: info.screen)
            if screen != info.screen {
                info.screen = screen
                startPipeline()
            }
        case "mouse", "wheel", "key", "text":
            guard authenticated, server?.config.allowRemoteInput == true else { return }
            input?.handle(message)
        default:
            break
        }
    }

    private func handleHello(_ message: [String: Any]) {
        guard let server else { return }
        let config = server.config
        let touchPoints = message["touch"] as? Int ?? 0
        let ua = message["ua"] as? String ?? userAgent
        info.platform = ClientPlatform.detect(userAgent: ua, touchPoints: touchPoints)
        info.name = (message["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(ClientPlatform.browserName(userAgent: ua)) on \(info.platform.label)"
        info.screen = Self.screen(from: message, fallback: info.screen)
        supportsH264 = (message["codecs"] as? [String])?.contains("h264") ?? false
        if !hasGreeted {
            if let mode = (message["mode"] as? String).flatMap(DisplayMode.init(rawValue:)) { info.params.mode = mode }
            if let retina = message["retina"] as? Bool { info.params.retina = retina }
        }
        hasGreeted = true

        guard config.screenSharingEnabled else {
            socket.sendJSON(["t": "error", "message": "Screen sharing is turned off on \(config.macName)."])
            socket.close()
            return
        }

        let code = (message["code"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if config.requirePairingCode {
            if server.isLockedOut(info.address) {
                socket.sendJSON(["t": "auth", "ok": false, "message": "Too many wrong codes. Try again in a minute."])
                return
            }
            if code != config.pairingCode {
                if !code.isEmpty { server.recordFailedPairing(info.address) }
                info.state = .awaitingCode
                server.publishSessions()
                socket.sendJSON(["t": "auth", "ok": false,
                                 "message": code.isEmpty ? "Enter the pairing code shown on your Mac." : "That pairing code isn't right."])
                return
            }
        }

        authenticated = true
        socket.sendJSON(["t": "auth", "ok": true, "name": config.macName])
        startPipeline()
    }

    private static func screen(from message: [String: Any], fallback: ClientScreen) -> ClientScreen {
        let width = message["w"] as? Int ?? fallback.width
        let height = message["h"] as? Int ?? fallback.height
        let scale = message["dpr"] as? Double ?? fallback.scale
        return ClientScreen(width: min(max(width, 200), 8192), height: min(max(height, 200), 8192),
                            scale: min(max(scale, 1), 4))
    }

    // MARK: Pipeline

    private func startPipeline() {
        guard let server, !stopped else { return }
        pipeline?.stop()
        input?.releaseAll()
        input = nil
        generation += 1
        let current = generation

        let codec: VideoCodec = info.params.codec == .h264 && supportsH264 ? .h264 : .jpeg
        info.activeCodec = codec
        info.state = .starting
        inFlight = 0
        needsKeyframe = true
        server.publishSessions()

        let pipeline = StreamPipeline(params: info.params, codec: codec, client: info.screen, clientName: info.name,
                                      showsCursor: server.config.showCursor, serial: Self.serial(for: info.name))
        let queue = server.queue
        pipeline.onReady = { [weak self] geometry in
            queue.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.pipelineReady(geometry)
            }
        }
        pipeline.onFrame = { [weak self] frame in
            queue.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.deliver(frame)
            }
        }
        pipeline.onError = { [weak self] message in
            queue.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.info.state = .failed(message)
                self.socket.sendJSON(["t": "error", "message": message])
                self.server?.publishSessions()
            }
        }
        self.pipeline = pipeline
        pipeline.start()
    }

    private func pipelineReady(_ geometry: StreamGeometry) {
        info.streamWidth = geometry.width
        info.streamHeight = geometry.height
        info.state = .streaming
        input = InputController(displayID: geometry.displayID)
        lastAck = Date()
        socket.sendJSON([
            "t": "config",
            "codec": geometry.codec.rawValue,
            "width": geometry.width,
            "height": geometry.height,
            "mode": info.params.mode.rawValue,
            "fps": info.params.fps,
            "retina": info.params.retina,
        ])
        pipeline?.requestKeyframe()
        server?.publishSessions()
    }

    private func deliver(_ frame: EncodedFrame) {
        guard info.state == .streaming else { return }

        // A browser that stopped acknowledging (tab hidden, decoder stalled)
        // gets a fresh start rather than a frozen stream.
        if inFlight > 0, Date().timeIntervalSince(lastAck) > 2 {
            inFlight = 0
            needsKeyframe = true
            pipeline?.requestKeyframe()
        }

        if frame.codec == .h264 {
            if needsKeyframe, !frame.isKeyframe { return }
            if inFlight >= maxInFlight {
                // Dropping a P-frame breaks the reference chain; resync on a key frame.
                needsKeyframe = true
                pipeline?.requestKeyframe()
                return
            }
            needsKeyframe = false
        } else if inFlight >= maxInFlight {
            return
        }

        let packet = frame.packet
        inFlight += 1
        framesSent += 1
        bytesSent += packet.count
        socket.sendBinary(packet)
    }

    func tickStats() {
        info.fps = Double(framesSent)
        info.kbps = Double(bytesSent * 8) / 1000
        if !rttSamples.isEmpty {
            info.rttMs = rttSamples.reduce(0, +) / Double(rttSamples.count)
        }
        framesSent = 0
        bytesSent = 0
        rttSamples.removeAll()
        if authenticated {
            socket.sendJSON(["t": "stats", "fps": info.fps, "kbps": info.kbps, "rtt": info.rttMs])
        }
    }

    private func teardown() {
        stopped = true
        pipeline?.stop()
        pipeline = nil
        input?.releaseAll()
        input = nil
        server?.sessionEnded(self)
    }

    /// Stable per-device serial so macOS remembers the virtual display's arrangement.
    private static func serial(for name: String) -> UInt32 {
        name.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
    }
}
