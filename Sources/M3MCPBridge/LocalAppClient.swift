import Darwin
import Foundation
import M3MCPCore

/// Talks to M3MCPApp over its Unix domain socket.
///
/// The protocol is still HTTP/JSON, but `URLSession` cannot open a Unix socket, so the request is
/// written to the socket directly. The app closes the connection after each response, so reading to
/// EOF is enough to get the whole body.
final class LocalAppClient {
    private let socketURL: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "de.markzimmermann.m3mcp.bridge.client")

    /// Speech recognition and transcript searches can take minutes; a short timeout would report the
    /// app as unreachable while it is still working.
    init(socketURL: URL = M3MCPEndpoint.socketURL, timeout: TimeInterval = 600) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    func call(tool: String, arguments: [String: Any]) async -> ToolResponse {
        let path = "/tools/\(tool.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tool)"

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: arguments, options: [])
        } catch {
            return ToolResponse(
                ok: false,
                source: "M3MCPBridge",
                message: "Could not encode tool arguments: \(error.localizedDescription)"
            )
        }

        do {
            let response = try await send(method: "POST", path: path, body: body)
            guard (200..<500).contains(response.status) else {
                return ToolResponse(
                    ok: false,
                    source: "M3MCPBridge",
                    message: "Local app returned HTTP \(response.status)."
                )
            }
            return try M3JSON.makeDecoder().decode(ToolResponse.self, from: response.body)
        } catch let failure as TransportFailure {
            return ToolResponse(ok: false, source: "M3MCPBridge", message: failure.message)
        } catch {
            return ToolResponse(
                ok: false,
                source: "M3MCPBridge",
                message: "Local app returned an unreadable response: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Transport

    private struct HTTPReply {
        let status: Int
        let body: Data
    }

    private struct TransportFailure: Error {
        let message: String
    }

    private func send(method: String, path: String, body: Data) async throws -> HTTPReply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [socketURL, timeout] in
                do {
                    let reply = try Self.exchange(
                        socketPath: socketURL.path,
                        method: method,
                        path: path,
                        body: body,
                        timeout: timeout
                    )
                    continuation.resume(returning: reply)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func exchange(
        socketPath: String,
        method: String,
        path: String,
        body: Data,
        timeout: TimeInterval
    ) throws -> HTTPReply {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TransportFailure(message: "Cannot create a local socket: \(systemMessage(errno)).")
        }
        defer { close(descriptor) }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var window = timeval(
            tv_sec: Int(timeout),
            tv_usec: 0
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count <= M3MCPEndpoint.maximumSocketPathLength else {
            throw TransportFailure(message: "Socket path is too long: \(socketPath)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, socketPath, capacity)
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connected == 0 else {
            throw TransportFailure(
                message: "M3MCPApp is not reachable at \(socketPath). Start the macOS app first. (\(systemMessage(errno)))"
            )
        }

        var request = Data()
        request.append(Data("\(method) \(path) HTTP/1.1\r\n".utf8))
        request.append(Data("Host: localhost\r\n".utf8))
        request.append(Data("Content-Type: application/json\r\n".utf8))
        request.append(Data("Content-Length: \(body.count)\r\n".utf8))
        request.append(Data("Connection: close\r\n\r\n".utf8))
        request.append(body)

        try writeAll(request, to: descriptor)
        let raw = try readToEnd(from: descriptor)
        return try parseReply(raw)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else {
                    throw TransportFailure(message: "Writing to the local socket failed: \(systemMessage(errno)).")
                }
                offset += written
            }
        }
    }

    private static func readToEnd(from descriptor: Int32) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }

            if count == 0 {
                return buffer
            }

            guard count > 0 else {
                throw TransportFailure(message: "Reading from the local socket failed: \(systemMessage(errno)).")
            }

            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private static func parseReply(_ data: Data) throws -> HTTPReply {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8),
              let statusLine = headerText.components(separatedBy: "\r\n").first
        else {
            throw TransportFailure(message: "The local app sent a malformed response.")
        }

        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw TransportFailure(message: "The local app sent an unreadable status line: \(statusLine)")
        }

        return HTTPReply(status: status, body: Data(data[headerEnd.upperBound...]))
    }

    private static func systemMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
