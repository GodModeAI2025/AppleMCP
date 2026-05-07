import Foundation
import M3MCPCore
import Network

final class LocalHTTPServer {
    typealias ToolHandler = (String, [String: JSONValue]) async -> ToolResponse
    typealias StatusHandler = () async -> StatusResponse

    private let port: UInt16
    private let toolHandler: ToolHandler
    private let statusHandler: StatusHandler
    private let queue = DispatchQueue(label: "de.markzimmermann.m3mcp.http")
    private var listener: NWListener?

    init(port: UInt16, toolHandler: @escaping ToolHandler, statusHandler: @escaping StatusHandler) {
        self.port = port
        self.toolHandler = toolHandler
        self.statusHandler = statusHandler
    }

    func start() throws {
        if listener != nil {
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { state in
            FileHandle.standardError.write(Data("[M3MCP] NWListener state: \(state)\n".utf8))
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = self.parseRequest(nextBuffer) {
                Task {
                    await self.respond(to: request, on: connection)
                }
            } else if nextBuffer.count < 1_000_000 {
                self.receive(on: connection, buffer: nextBuffer)
            } else {
                self.send(status: 413, body: ["error": "Request too large"], on: connection)
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let body = data[bodyStart..<(bodyStart + contentLength)]
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), body: Data(body))
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        if request.method == "GET", request.path == "/health" || request.path == "/status" {
            let status = await statusHandler()
            send(status: 200, codable: status, on: connection)
            return
        }

        if request.method == "POST", request.path.hasPrefix("/tools/") {
            let tool = String(request.path.dropFirst("/tools/".count)).removingPercentEncoding ?? ""
            let input = (try? M3JSON.makeDecoder().decode([String: JSONValue].self, from: request.body)) ?? [:]
            let response = await toolHandler(tool, input)
            send(status: response.ok ? 200 : 400, codable: response, on: connection)
            return
        }

        send(status: 404, body: ["error": "Not found"], on: connection)
    }

    private func send<T: Encodable>(status: Int, codable: T, on connection: NWConnection) {
        let data: Data
        do {
            data = try M3JSON.makeEncoder().encode(codable)
        } catch {
            send(status: 500, body: ["error": error.localizedDescription], on: connection)
            return
        }

        send(status: status, data: data, on: connection)
    }

    private func send(status: Int, body: [String: String], on connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        send(status: status, data: data, on: connection)
    }

    private func send(status: Int, data: Data, on connection: NWConnection) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        default: reason = "Internal Server Error"
        }

        var response = Data()
        response.append("HTTP/1.1 \(status) \(reason)\r\n".data(using: .utf8)!)
        response.append("Content-Type: application/json; charset=utf-8\r\n".data(using: .utf8)!)
        response.append("Content-Length: \(data.count)\r\n".data(using: .utf8)!)
        response.append("Connection: close\r\n\r\n".data(using: .utf8)!)
        response.append(data)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
