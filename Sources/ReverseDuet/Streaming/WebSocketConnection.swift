import CryptoKit
import Foundation
import Network

/// Minimal RFC 6455 server-side WebSocket over an `NWConnection`.
/// All methods must be called on the queue passed to `init`.
final class WebSocketConnection {
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer: [UInt8]
    private var fragments: [UInt8] = []
    private var fragmentOpcode: UInt8 = 0
    private var closed = false

    /// Bytes handed to the network stack but not yet written to the socket.
    private(set) var pendingBytes = 0

    static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    init(connection: NWConnection, queue: DispatchQueue, initialBytes: [UInt8]) {
        self.connection = connection
        self.queue = queue
        self.buffer = initialBytes
    }

    func start() {
        parseFrames()
        receive()
    }

    func sendText(_ text: String) {
        send(opcode: 0x1, payload: Data(text.utf8))
    }

    func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text)
    }

    func sendBinary(_ data: Data) {
        send(opcode: 0x2, payload: data)
    }

    func close() {
        guard !closed else { return }
        send(opcode: 0x8, payload: Data([0x03, 0xE8])) // 1000 normal closure
        finish()
    }

    // MARK: Private

    private func send(opcode: UInt8, payload: Data) {
        guard !closed else { return }
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        let size = frame.count
        pendingBytes += size
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.pendingBytes -= size
                if error != nil { self.finish() }
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.buffer.append(contentsOf: data)
                    self.parseFrames()
                }
                if isComplete || error != nil {
                    self.finish()
                } else if !self.closed {
                    self.receive()
                }
            }
        }
    }

    private func parseFrames() {
        while !closed, buffer.count >= 2 {
            let fin = buffer[0] & 0x80 != 0
            let opcode = buffer[0] & 0x0F
            let masked = buffer[1] & 0x80 != 0
            var length = Int(buffer[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                length = 0
                for i in 2..<10 { length = length << 8 | Int(buffer[i]) }
                offset = 10
            }
            // Browsers only send small control/input messages.
            guard length <= 1 << 20 else { finish(); return }
            let maskLength = masked ? 4 : 0
            guard buffer.count >= offset + maskLength + length else { return }

            var payload = Array(buffer[(offset + maskLength)..<(offset + maskLength + length)])
            if masked {
                let mask = Array(buffer[offset..<(offset + 4)])
                for i in payload.indices { payload[i] ^= mask[i & 3] }
            }
            buffer.removeFirst(offset + maskLength + length)
            handleFrame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x0: // continuation
            fragments.append(contentsOf: payload)
            if fin {
                deliver(opcode: fragmentOpcode, payload: fragments)
                fragments.removeAll()
            }
        case 0x1, 0x2:
            if fin {
                deliver(opcode: opcode, payload: payload)
            } else {
                fragmentOpcode = opcode
                fragments = payload
            }
        case 0x8:
            close()
        case 0x9:
            send(opcode: 0xA, payload: Data(payload))
        default:
            break
        }
    }

    private func deliver(opcode: UInt8, payload: [UInt8]) {
        if opcode == 0x1 {
            onText?(String(decoding: payload, as: UTF8.self))
        } else {
            onBinary?(Data(payload))
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let handler = onClose
        onClose = nil
        handler?()
    }
}
