import Foundation
import Network
import Security

protocol StreamServerDelegate: AnyObject {
    /// Called on the server queue.
    func serverDidUpdateSessions(_ sessions: [SessionInfo])
    /// Called on the server queue.
    func serverDidChangeState(running: Bool, error: String?)
    /// Called on the server queue.
    func serverDidChangeSecurePort(_ port: Int?)
}

/// Listens on the LAN, serves the browser client and owns every `ClientSession`.
final class StreamServer {
    let queue = DispatchQueue(label: "reverse-duet.server", qos: .userInitiated)
    weak var delegate: StreamServerDelegate?

    private var listener: NWListener?
    private var secureListener: NWListener?
    /// Port of the HTTPS/WSS listener, when it is running.
    private(set) var securePort: Int?
    private var httpConnections: [ObjectIdentifier: HTTPConnection] = [:]
    private var sessions: [UUID: ClientSession] = [:]
    private var statsTimer: DispatchSourceTimer?
    private var failedPairings: [String: (count: Int, lockedUntil: Date)] = [:]

    private let configLock = NSLock()
    private var storedConfig = ServerConfig()

    var config: ServerConfig {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return storedConfig
        }
        set {
            configLock.lock()
            storedConfig = newValue
            configLock.unlock()
        }
    }

    // MARK: Listening

    /// Starts plain HTTP on `port` and, when an identity is given, HTTPS on `port + 1`.
    func start(port: Int, identity: SecIdentity?) {
        queue.async { [self] in
            stopListening()
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
                delegate?.serverDidChangeState(running: false, error: "Invalid port \(port).")
                return
            }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: nwPort)
                listener.service = NWListener.Service(name: config.macName, type: "_http._tcp")
                listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                self.listener = listener
                startStatsTimer()
            } catch {
                delegate?.serverDidChangeState(running: false, error: error.localizedDescription)
                return
            }

            // The secure link is optional; failing to start it never blocks plain HTTP.
            if let identity, let secIdentity = sec_identity_create(identity),
               let securePort = NWEndpoint.Port(rawValue: UInt16(clamping: port + 1)) {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
                let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
                parameters.allowLocalEndpointReuse = true
                if let listener = try? NWListener(using: parameters, on: securePort) {
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, let listener, listener === self.secureListener else { return }
                        switch state {
                        case .ready: self.securePort = port + 1
                        case .failed, .cancelled: self.securePort = nil
                        default: break
                        }
                        self.delegate?.serverDidChangeSecurePort(self.securePort)
                    }
                    listener.start(queue: queue)
                    secureListener = listener
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopListening()
            delegate?.serverDidChangeState(running: false, error: nil)
        }
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        secureListener?.cancel()
        secureListener = nil
        if securePort != nil {
            securePort = nil
            delegate?.serverDidChangeSecurePort(nil)
        }
        statsTimer?.cancel()
        statsTimer = nil
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        for http in httpConnections.values { http.connection.cancel() }
        httpConnections.removeAll()
        publishSessions()
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            delegate?.serverDidChangeState(running: true, error: nil)
        case .failed(let error):
            let message: String
            if case .posix(let code) = error, code == .EADDRINUSE {
                message = "Port \(listener?.port?.rawValue ?? 0) is already in use. Pick another port in Settings."
            } else {
                message = error.localizedDescription
            }
            listener?.cancel()
            listener = nil
            delegate?.serverDidChangeState(running: false, error: message)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let http = HTTPConnection(connection: connection, server: self)
        httpConnections[ObjectIdentifier(http)] = http
        http.start()
    }

    // MARK: Called by connections (on `queue`)

    func connectionFinished(_ http: HTTPConnection) {
        httpConnections.removeValue(forKey: ObjectIdentifier(http))
    }

    func upgrade(_ http: HTTPConnection, request: HTTPRequest, leftover: [UInt8]) {
        httpConnections.removeValue(forKey: ObjectIdentifier(http))
        var address = "unknown"
        if case .hostPort(let host, _) = http.connection.endpoint {
            address = "\(host)".replacingOccurrences(of: "::ffff:", with: "")
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
        }
        let socket = WebSocketConnection(connection: http.connection, queue: queue, initialBytes: leftover)
        let session = ClientSession(server: self, socket: socket, address: address,
                                    userAgent: request.headers["user-agent"] ?? "")
        sessions[session.id] = session
        session.start()
    }

    func sessionEnded(_ session: ClientSession) {
        sessions.removeValue(forKey: session.id)
        publishSessions()
    }

    /// Pairing attempts are limited per IP so the 4-digit code can't be brute forced.
    func isLockedOut(_ address: String) -> Bool {
        guard let entry = failedPairings[address] else { return false }
        return entry.lockedUntil > Date()
    }

    func recordFailedPairing(_ address: String) {
        var entry = failedPairings[address] ?? (count: 0, lockedUntil: Date.distantPast)
        entry.count += 1
        if entry.count >= 5 {
            entry = (count: 0, lockedUntil: Date().addingTimeInterval(60))
        }
        failedPairings[address] = entry
    }

    func publishSessions() {
        let visible = sessions.values
            .filter(\.hasGreeted)
            .map(\.info)
            .sorted { $0.name < $1.name }
        delegate?.serverDidUpdateSessions(visible)
    }

    // MARK: Called by the UI

    func update(sessionID: UUID, params: StreamParameters) {
        queue.async { [self] in sessions[sessionID]?.update(params: params) }
    }

    func disconnect(sessionID: UUID) {
        queue.async { [self] in sessions[sessionID]?.stop() }
    }

    func disconnectAll() {
        queue.async { [self] in
            for session in sessions.values { session.stop() }
        }
    }

    // MARK: Stats

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for session in self.sessions.values { session.tickStats() }
            if !self.sessions.isEmpty { self.publishSessions() }
        }
        timer.resume()
        statsTimer = timer
    }
}
