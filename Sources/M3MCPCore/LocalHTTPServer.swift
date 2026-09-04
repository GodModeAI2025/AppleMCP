import Darwin
import Foundation

/// Serves the MCP tool endpoint over a Unix domain socket.
///
/// The transport is HTTP so the request shape stays familiar (`curl --unix-socket` still works), but
/// the socket replaces the former loopback TCP port. The filesystem carries part of the access
/// control — the socket lives in a `0700` directory and is itself `0600`, so a sandboxed app cannot
/// reach it and neither can a web page — and that is where it used to end. It no longer does: every
/// request other than `GET /health` has to present the capability token, and where the app could
/// work out which binary its bridge is, the connecting process is checked against that binary's code
/// directory hash. `SocketAuthorizer` holds the rules, `PeerIdentity` reads the peer.
///
/// This type lives in M3MCPCore rather than in the app target so the authorization path can be
/// exercised by `swift test`. Security code that only runs inside a GUI app is security code nobody
/// checks.
public final class LocalHTTPServer {
    public typealias ToolHandler = (String, [String: JSONValue]) async -> ToolResponse
    public typealias StatusHandler = () async -> StatusResponse
    public typealias AuditHandler = (AccessAttempt) -> Void

    private let socketURL: URL
    private let toolHandler: ToolHandler
    private let statusHandler: StatusHandler
    private let authorizer: SocketAuthorizer
    private let auditHandler: AuditHandler?
    private let acceptQueue = DispatchQueue(label: "de.markzimmermann.m3mcp.accept")
    private let connectionQueue = DispatchQueue(
        label: "de.markzimmermann.m3mcp.connections",
        attributes: .concurrent
    )
    private var acceptSource: DispatchSourceRead?
    private var listeningDescriptor: Int32 = -1

    private let maximumRequestBytes = 1_000_000

    public init(
        socketURL: URL,
        authorizer: SocketAuthorizer,
        toolHandler: @escaping ToolHandler,
        statusHandler: @escaping StatusHandler,
        auditHandler: AuditHandler? = nil
    ) {
        self.socketURL = socketURL
        self.authorizer = authorizer
        self.toolHandler = toolHandler
        self.statusHandler = statusHandler
        self.auditHandler = auditHandler
    }

    public struct StartFailure: LocalizedError {
        public let message: String

        public var errorDescription: String? { message }

        init(_ message: String, errno code: Int32? = nil) {
            if let code {
                self.message = "\(message): \(String(cString: strerror(code)))"
            } else {
                self.message = message
            }
        }
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard acceptSource == nil else {
            return
        }

        let path = socketURL.path
        guard path.utf8.count <= M3MCPEndpoint.maximumSocketPathLength else {
            throw StartFailure("Socket path is too long for a Unix domain socket: \(path)")
        }

        try prepareDirectory()

        // A socket file left behind by a crash would make bind fail with EADDRINUSE.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw StartFailure("Cannot create the local socket", errno: errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                _ = strlcpy(destination, path, pathCapacity)
            }
        }

        // Create the socket as 0600 rather than widening it after the fact.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                bind(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)

        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw StartFailure("Cannot bind \(path)", errno: code)
        }

        // The accept loop drains the backlog on every readiness event, so it must not block on the
        // last, empty accept.
        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }

        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw StartFailure("Cannot listen on \(path)", errno: code)
        }

        // Belt and braces: umask covers the create, chmod covers an inherited-mode surprise.
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()

        listeningDescriptor = descriptor
        acceptSource = source
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listeningDescriptor = -1
        unlink(socketURL.path)
    }

    private func prepareDirectory() throws {
        let directory = socketURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        do {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            } else {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            throw StartFailure("Cannot prepare \(directory.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Accepting

    private func acceptPendingConnections() {
        while true {
            let client = accept(listeningDescriptor, nil, nil)
            guard client >= 0 else {
                return
            }

            // Without this a client that hangs up mid-response would kill the app with SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            // Darwin does not pass O_NONBLOCK on to accepted sockets, but be explicit: the read and
            // write helpers below are written for blocking descriptors.
            let clientFlags = fcntl(client, F_GETFL, 0)
            if clientFlags >= 0 {
                _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
            }

            // Read while the connection is still open and before any work is queued: the audit
            // token identifies the process that connected, and a pid alone could be recycled.
            let peer = PeerIdentity.resolve(descriptor: client)

            connectionQueue.async { [weak self] in
                self?.serve(client, peer: peer)
            }
        }
    }

    private func serve(_ client: Int32, peer: PeerIdentity) {
        defer { close(client) }

        switch readRequest(from: client) {
        case .request(let request):
            // The handlers are async; this connection thread waits for them.
            let done = DispatchSemaphore(value: 0)
            Task { [weak self] in
                await self?.respond(to: request, on: client, peer: peer)
                done.signal()
            }
            done.wait()
        case .tooLarge:
            send(status: 413, body: ["error": "Request too large"], to: client)
        case .failed:
            send(status: 400, body: ["error": "Malformed request"], to: client)
        }
    }

    private enum ReadOutcome {
        case request(HTTPRequest)
        case tooLarge
        case failed
    }

    private func readRequest(from client: Int32) -> ReadOutcome {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                read(client, raw.baseAddress, raw.count)
            }

            if count <= 0 {
                return .failed
            }

            buffer.append(contentsOf: chunk[0..<count])

            if let request = parseRequest(buffer) {
                return .request(request)
            }

            if buffer.count > maximumRequestBytes {
                return .tooLarge
            }
        }
    }

    // MARK: - Request model

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
        /// Header names lowercased, so lookups do not depend on client casing.
        let headers: [String: String]
    }

    /// Kept from the loopback era as defence in depth.
    ///
    /// A browser cannot open a Unix socket at all, so these checks should never fire now. They cost
    /// nothing, and they keep the endpoint honest if the transport ever changes back.
    private enum RequestGuard {
        /// Present only on browser-issued requests.
        static let browserOnlyHeaders = ["origin", "referer", "sec-fetch-site", "sec-fetch-mode"]

        /// Returns a rejection reason, or nil when the request is acceptable.
        static func rejection(for request: HTTPRequest) -> String? {
            for header in browserOnlyHeaders where request.headers[header] != nil {
                return "Requests carrying '\(header)' are refused: this endpoint is not reachable from a browser."
            }

            // Enforced on tool calls only, so /health stays trivially checkable.
            if request.method == "POST", request.path.hasPrefix("/tools/") {
                let contentType = request.headers["content-type"] ?? ""
                guard contentType.lowercased().contains("application/json") else {
                    return "Tool calls require Content-Type: application/json."
                }
            }

            return nil
        }
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[data.startIndex..<headerEnd.lowerBound]
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

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let contentLength = Int(headers["content-length"] ?? "") ?? 0

        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let body = data[bodyStart..<(bodyStart + contentLength)]
        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            body: Data(body),
            headers: headers
        )
    }

    // MARK: - Responding

    private func respond(to request: HTTPRequest, on client: Int32, peer: PeerIdentity) async {
        if let reason = RequestGuard.rejection(for: request) {
            report(request, peer: peer, allowed: false, reason: reason)
            send(status: 403, reason: reason, path: request.path, to: client)
            return
        }

        let decision = authorizer.authorize(
            method: request.method,
            path: request.path,
            authorizationHeader: request.headers["authorization"],
            peer: peer
        )

        if case .deny(let status, let reason) = decision {
            report(request, peer: peer, allowed: false, reason: reason)
            send(status: status, reason: reason, path: request.path, to: client)
            return
        }

        report(request, peer: peer, allowed: true, reason: nil)

        if request.method == "GET", request.path == "/health" {
            // The documented probe, and the one path that answers without a token — so it must not
            // carry the activity log, which holds the arguments and results of past tool calls.
            let status = await statusHandler()
            send(status: 200, codable: Self.publicStatus(status, authorizer: authorizer), to: client)
            return
        }

        if request.method == "GET", request.path == "/status" {
            let status = await statusHandler()
            send(status: 200, codable: status, to: client)
            return
        }

        if request.method == "POST", request.path.hasPrefix("/tools/") {
            let tool = String(request.path.dropFirst("/tools/".count)).removingPercentEncoding ?? ""
            let input = (try? M3JSON.makeDecoder().decode([String: JSONValue].self, from: request.body)) ?? [:]
            let response = await toolHandler(tool, input)
            send(status: response.ok ? 200 : 400, codable: response, to: client)
            return
        }

        send(status: 404, reason: "Not found", path: request.path, to: client)
    }

    /// `/health` without the activity log, plus one line saying how the endpoint is guarded. A caller
    /// that wants the log asks `/status` and presents the token.
    private static func publicStatus(_ status: StatusResponse, authorizer: SocketAuthorizer) -> StatusResponse {
        let authenticationRow = ServiceHealth(
            name: "Client Authentication",
            endpoint: "m3mcp://auth",
            mode: "capability token + peer code identity",
            state: authorizer.pinningDescription
        )
        // The app lists the same row in its own service list, and /health would otherwise show it
        // twice.
        let services = status.services.contains { $0.name == authenticationRow.name }
            ? status.services
            : status.services + [authenticationRow]

        return StatusResponse(
            ok: status.ok,
            version: status.version,
            endpoint: status.endpoint,
            services: services,
            recentActivity: []
        )
    }

    private func report(_ request: HTTPRequest, peer: PeerIdentity, allowed: Bool, reason: String?) {
        guard let auditHandler else { return }
        auditHandler(
            AccessAttempt(method: request.method, path: request.path, peer: peer, allowed: allowed, reason: reason)
        )
    }

    /// A refusal on a tool path has to decode as a `ToolResponse`, because that is the only shape
    /// `LocalAppClient` knows how to read; anything else reaches the MCP client as "unreadable
    /// response" instead of as the reason it was refused.
    private func send(status: Int, reason: String, path: String, to client: Int32) {
        if path.hasPrefix("/tools/") {
            send(status: status, codable: ToolResponse(ok: false, source: "M3MCP Server", message: reason), to: client)
        } else {
            send(status: status, body: ["error": reason], to: client)
        }
    }

    private func send<T: Encodable>(status: Int, codable: T, to client: Int32) {
        let data: Data
        do {
            data = try M3JSON.makeEncoder().encode(codable)
        } catch {
            send(status: 500, body: ["error": error.localizedDescription], to: client)
            return
        }

        send(status: status, data: data, to: client)
    }

    private func send(status: Int, body: [String: String], to client: Int32) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        send(status: status, data: data, to: client)
    }

    private func send(status: Int, data: Data, to client: Int32) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        default: reason = "Internal Server Error"
        }

        var response = Data()
        response.append(Data("HTTP/1.1 \(status) \(reason)\r\n".utf8))
        response.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
        response.append(Data("Content-Length: \(data.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(data)

        writeAll(response, to: client)
    }

    private func writeAll(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(client, base.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    return
                }
                offset += written
            }
        }
    }
}
