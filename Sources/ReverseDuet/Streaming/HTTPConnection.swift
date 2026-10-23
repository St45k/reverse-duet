import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    /// Parses a request head from `buffer`, removing the consumed bytes.
    static func parse(_ buffer: inout [UInt8]) -> HTTPRequest? {
        let terminator: [UInt8] = [13, 10, 13, 10]
        guard buffer.count >= 4,
              let end = (0...(buffer.count - 4)).first(where: { Array(buffer[$0..<($0 + 4)]) == terminator }) else { return nil }
        let head = String(decoding: buffer[0..<end], as: UTF8.self)
        buffer.removeFirst(end + 4)

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return HTTPRequest(method: String(requestLine[0]), path: path, headers: headers)
    }
}

/// Serves the browser client and upgrades `/ws` to a WebSocket.
final class HTTPConnection {
    let connection: NWConnection
    private weak var server: StreamServer?
    private var buffer: [UInt8] = []

    init(connection: NWConnection, server: StreamServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        guard let server else { return }
        connection.start(queue: server.queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(contentsOf: data) }
            if let request = HTTPRequest.parse(&self.buffer) {
                self.handle(request)
            } else if self.buffer.count > 64 * 1024 || isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ request: HTTPRequest) {
        guard let server else { return close() }
        guard request.method == "GET" else {
            return respond(status: "405 Method Not Allowed", type: "text/plain", body: Data("Method not allowed".utf8))
        }

        if request.path == "/ws" {
            guard request.headers["upgrade"]?.lowercased() == "websocket",
                  let key = request.headers["sec-websocket-key"] else {
                return respond(status: "400 Bad Request", type: "text/plain", body: Data("Expected a WebSocket upgrade".utf8))
            }
            let response = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(WebSocketConnection.acceptKey(for: key))\r\n\r\n"
            let leftover = buffer
            buffer.removeAll()
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            server.upgrade(self, request: request, leftover: leftover)
            return
        }

        if request.path == "/info" {
            let config = server.config
            var info: [String: Any] = [
                "name": config.macName,
                "requiresCode": config.requirePairingCode,
                "version": AppInfo.version,
                "defaults": [
                    "mode": config.defaults.mode.rawValue,
                    "retina": config.defaults.retina,
                ],
            ]
            if let securePort = server.securePort { info["securePort"] = securePort }
            let body = (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8)
            return respond(status: "200 OK", type: "application/json", body: body)
        }

        let name = request.path == "/" ? "index.html" : String(request.path.dropFirst())
        if let file = WebAssets.file(named: name) {
            respond(status: "200 OK", type: file.contentType, body: file.data)
        } else {
            respond(status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func respond(status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        connection.cancel()
        server?.connectionFinished(self)
    }
}
