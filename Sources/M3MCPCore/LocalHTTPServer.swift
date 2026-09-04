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
/// Availability is part of that access control, because authorization cannot happen before the
/// request has been read whole: the token is a header. So an accepted connection is read through a
/// dispatch source rather than by a thread parked in `read`. Until a complete request arrives it
/// costs a descriptor and a deadline and nothing else, and a thread is spent only once there is
/// something to answer. Two rules follow from that, and both are needed. A silent connection gets a
/// deadline, and when the slots are full a silent connection is the one that loses its place to a
/// new arrival. Without the first, 120 connections that say nothing were enough for any local
/// process to take the endpoint away from the client that holds the token, `/health` included.
/// Without the second, 128 of them still were.
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

    /// How long a connection may take to deliver a complete request, and how long a reply may take
    /// to go out.
    ///
    /// Authorization happens *after* the request has been read whole — it has to, the token is a
    /// header — so until then an unauthenticated connection costs a thread. Without a deadline a
    /// process that connects and says nothing keeps that thread until someone notices. Both a
    /// per-read timeout and a deadline across the whole request are needed: the first ends a silent
    /// connection, the second ends one that dribbles a byte at a time.
    private let requestTimeout: TimeInterval

    /// How many accepted connections may be waiting for a request at once.
    ///
    /// A waiting connection costs a descriptor and a dispatch source, so this bounds the endpoint's
    /// share of the process's file descriptors rather than its threads.
    ///
    /// The cap does not decide who gets turned away when it is reached. A connection that has sent
    /// nothing yields its slot to a newer one, so filling every slot buys a silent process a burst
    /// and not an outage. See `acceptPendingConnections`.
    private let maximumOpenConnections: Int

    /// How many complete requests may be served at once.
    ///
    /// `connectionQueue` is concurrent and `serve` blocks on it, so every request in flight holds a
    /// thread out of a pool not much larger than 64. Only a connection that has already delivered a
    /// whole request gets one, which is the difference between this cap and the one above: silence
    /// is cheap, and a thread is the price of having said something.
    private let maximumConcurrentRequests: Int

    private let connectionCountLock = NSLock()
    fileprivate var openConnections = 0
    fileprivate var requestsInFlight = 0

    /// Serial: every pending connection's reads, its deadline and its teardown run here, so the
    /// state of a connection needs no lock of its own.
    private let readQueue = DispatchQueue(label: "de.markzimmermann.m3mcp.reads")

    /// Only ever touched on `readQueue`. `stop()` needs it: a connection waiting for a request holds
    /// a descriptor, and nothing else would close it before its deadline.
    private var pendingConnections: [PendingConnection] = []

    public init(
        socketURL: URL,
        authorizer: SocketAuthorizer,
        toolHandler: @escaping ToolHandler,
        statusHandler: @escaping StatusHandler,
        auditHandler: AuditHandler? = nil,
        requestTimeout: TimeInterval = 10,
        maximumOpenConnections: Int = 128,
        maximumConcurrentRequests: Int = 32
    ) {
        self.socketURL = socketURL
        self.authorizer = authorizer
        self.toolHandler = toolHandler
        self.statusHandler = statusHandler
        self.auditHandler = auditHandler
        self.requestTimeout = requestTimeout
        self.maximumOpenConnections = max(1, maximumOpenConnections)
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
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

        // The backlog is what the kernel holds between a client's connect and this server's accept.
        // At 16 a burst — an attacker's, or a client reconnecting while one is in flight — overran it
        // and the kernel answered ECONNREFUSED, which looks to a client like a server that is not
        // there. It is matched to the connection cap instead, and 128 is where Darwin tops out.
        guard listen(descriptor, Int32(min(maximumOpenConnections, 128))) == 0 else {
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

        readQueue.async { [weak self] in
            guard let self else { return }
            for connection in self.pendingConnections {
                self.finish(connection, writing: nil)
            }
        }
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

    /// One connection that has been accepted and has not yet delivered a complete request.
    ///
    /// It costs a file descriptor and a dispatch source. It does not cost a thread — that is the
    /// whole point of reading through a source instead of blocking on `read`.
    private final class PendingConnection {
        let descriptor: Int32
        var buffer = Data()
        var readSource: DispatchSourceRead?
        var timer: DispatchSourceTimer?
        var closed = false

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }
    }

    private func acceptPendingConnections() {
        while true {
            let client = accept(listeningDescriptor, nil, nil)
            guard client >= 0 else {
                return
            }

            prepare(client)

            // At the cap, the connection that just arrived is the wrong one to turn away. It is the
            // one that might have something to say; a slot held without a single byte in it belongs
            // to a connection that has already shown it has not. So the oldest silent connection is
            // dropped and the new one takes its place. That is what a cap alone did not do: a
            // process without a token can still fill every slot, but it cannot keep them, because
            // every arrival after that costs it the oldest slot it holds.
            //
            // The bridge writes its whole request in one call straight after `connect`, so it is out
            // of the silent set within microseconds and is never the connection picked. Exactly one
            // connection is refused either way; this only decides which, and it decides in favour of
            // the one that has not yet had its turn.
            if !claimSlot(\.openConnections, limit: maximumOpenConnections) {
                // Synchronous on purpose. `pendingConnections` belongs to `readQueue`, and waiting
                // here is also what stops the accept loop from running ahead of its own admissions
                // and holding an unbounded number of descriptors while it does.
                var displaced = false
                readQueue.sync { displaced = self.dropOldestSilentConnection() }

                // Nothing silent left means every slot holds a request being read, and then the
                // refusal is the honest answer. It is written best-effort on a non-blocking
                // descriptor: a client that will not read it must not stall the accept loop in turn.
                guard displaced, claimSlot(\.openConnections, limit: maximumOpenConnections) else {
                    refuse(client, status: 503, reason: "Too many open connections")
                    continue
                }
            }

            // Onto the read queue, which owns everything about a pending connection from here on.
            // Nothing else happens here: this loop is the only thing draining the listen backlog,
            // and every microsecond it spends on a connection is a microsecond in which the kernel
            // may answer somebody else's `connect` with ECONNREFUSED. Working out who the peer is
            // costs a signature check and belongs where it is needed, not in front of the queue.
            readQueue.async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                self.beginReading(client)
            }
        }
    }

    /// Ends the connection that has waited longest without sending a byte, so a newer one can have
    /// its slot. Runs on `readQueue`, which owns `pendingConnections`.
    ///
    /// Returns false when there is nothing silent to drop, which means every slot is held by a
    /// request that is actually being read. Those are not displaced: a half-read request is work in
    /// progress, and throwing it away would turn a full endpoint into a lossy one.
    private func dropOldestSilentConnection() -> Bool {
        guard let victim = pendingConnections.first(where: { $0.buffer.isEmpty && !$0.closed }) else {
            return false
        }

        finish(
            victim,
            writing: response(
                status: 503,
                body: ["error": "Displaced by a newer connection after sending nothing"]
            )
        )
        return true
    }

    /// Non-blocking, no SIGPIPE, and a send timeout for the reply.
    ///
    /// Non-blocking is what keeps a silent client cheap: the request is collected by a dispatch
    /// source, and a connection that sends nothing simply never fires one.
    private func prepare(_ client: Int32) {
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(client, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(client, F_SETFL, flags | O_NONBLOCK)
        }

        var deadline = Self.timeval(for: requestTimeout)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func timeval(for interval: TimeInterval) -> Darwin.timeval {
        let seconds = max(0.001, interval)
        let whole = Int(seconds)
        return Darwin.timeval(
            tv_sec: whole,
            tv_usec: Int32((seconds - Double(whole)) * 1_000_000)
        )
    }

    // MARK: - Reading a request without holding a thread

    /// Runs on `readQueue`.
    private func beginReading(_ client: Int32) {
        let connection = PendingConnection(descriptor: client)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: client, queue: readQueue)
        readSource.setEventHandler { [weak self] in
            self?.readAvailable(on: connection)
        }
        // The descriptor belongs to the source from here on, so nothing else closes it.
        readSource.setCancelHandler { close(client) }
        connection.readSource = readSource

        // The deadline is what an idle connection actually costs: this long, then the slot is back.
        let timer = DispatchSource.makeTimerSource(queue: readQueue)
        timer.schedule(deadline: .now() + requestTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.finish(
                connection,
                writing: self.response(
                    status: 408,
                    body: ["error": "No complete request within \(Int(self.requestTimeout)) seconds"]
                )
            )
        }
        connection.timer = timer
        pendingConnections.append(connection)

        timer.resume()
        readSource.resume()
    }

    /// Runs on `readQueue`, so everything it touches on the connection is serialized by the queue.
    private func readAvailable(on connection: PendingConnection) {
        guard !connection.closed else { return }

        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                read(connection.descriptor, raw.baseAddress, raw.count)
            }

            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(connection, writing: nil)
                return
            }

            if count == 0 {
                // The peer hung up before finishing its request.
                finish(connection, writing: nil)
                return
            }

            connection.buffer.append(contentsOf: chunk[0..<count])

            if let request = parseRequest(connection.buffer) {
                hand(request, of: connection)
                return
            }

            if connection.buffer.count > maximumRequestBytes {
                finish(connection, writing: response(status: 413, body: ["error": "Request too large"]))
                return
            }
        }
    }

    /// A complete request has arrived: only now is a thread worth spending on it.
    private func hand(_ request: HTTPRequest, of connection: PendingConnection) {
        // `dup` hands the open connection to the serving thread while the source keeps ownership of
        // the descriptor it was created with. Without it, cancelling the source would close the
        // socket out from under the reply.
        let served = dup(connection.descriptor)
        guard served >= 0 else {
            finish(connection, writing: nil)
            return
        }

        // Now, and not at `accept`: the peer is what authorization is decided on, so it is read for
        // a connection that has actually asked for something and never for one that only sat there.
        // `dup` shares the socket, so `LOCAL_PEERTOKEN` still names the process that connected, and
        // reading it here keeps that true even if the peer has since gone away.
        let peer = PeerIdentity.resolve(descriptor: served)
        finish(connection, writing: nil)

        // The refusal goes out while the descriptor is still non-blocking, so a client that will not
        // read it cannot hold up `readQueue` in the bargain.
        guard claimSlot(\.requestsInFlight, limit: maximumConcurrentRequests) else {
            refuse(served, status: 503, reason: "Too many requests in flight")
            return
        }

        // Back to blocking for the reply: `writeAll` is written for a blocking descriptor, and
        // SO_SNDTIMEO keeps it bounded.
        let flags = fcntl(served, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(served, F_SETFL, flags & ~O_NONBLOCK)
        }

        connectionQueue.async { [weak self] in
            guard let self else {
                close(served)
                return
            }
            defer { self.releaseSlot(\.requestsInFlight) }
            self.serve(request, on: served, peer: peer)
        }
    }

    /// Ends a pending connection: cancels its timer and its read source, writes an optional last
    /// reply, and gives the slot back. Idempotent, and only ever called on `readQueue`.
    private func finish(_ connection: PendingConnection, writing reply: Data?) {
        guard !connection.closed else { return }
        connection.closed = true

        if let reply {
            writeBestEffort(reply, to: connection.descriptor)
        }

        connection.timer?.cancel()
        connection.readSource?.cancel()
        connection.timer = nil
        connection.readSource = nil
        pendingConnections.removeAll { $0 === connection }
        releaseSlot(\.openConnections)
    }

    // MARK: - Limits

    private func claimSlot(_ counter: ReferenceWritableKeyPath<LocalHTTPServer, Int>, limit: Int) -> Bool {
        connectionCountLock.lock()
        defer { connectionCountLock.unlock() }
        guard self[keyPath: counter] < limit else { return false }
        self[keyPath: counter] += 1
        return true
    }

    private func releaseSlot(_ counter: ReferenceWritableKeyPath<LocalHTTPServer, Int>) {
        connectionCountLock.lock()
        self[keyPath: counter] = max(0, self[keyPath: counter] - 1)
        connectionCountLock.unlock()
    }

    private func refuse(_ client: Int32, status: Int, reason: String) {
        writeBestEffort(response(status: status, body: ["error": reason]), to: client)
        close(client)
    }

    /// One write on a non-blocking descriptor. What does not go out is dropped: this path exists to
    /// explain a refusal, not to guarantee delivery of one.
    private func writeBestEffort(_ data: Data, to client: Int32) {
        _ = data.withUnsafeBytes { raw in
            raw.baseAddress.map { write(client, $0, raw.count) }
        }
    }

    // MARK: - Serving

    private func serve(_ request: HTTPRequest, on client: Int32, peer: PeerIdentity) {
        defer { close(client) }

        // The handlers are async; this connection thread waits for them.
        let done = DispatchSemaphore(value: 0)
        Task { [weak self] in
            await self?.respond(to: request, on: client, peer: peer)
            done.signal()
        }
        done.wait()
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
        writeAll(response(status: status, data: data), to: client)
    }

    private func response(status: Int, body: [String: String]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return response(status: status, data: data)
    }

    private func response(status: Int, data: Data) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 408: reason = "Request Timeout"
        case 413: reason = "Payload Too Large"
        case 503: reason = "Service Unavailable"
        default: reason = "Internal Server Error"
        }

        var response = Data()
        response.append(Data("HTTP/1.1 \(status) \(reason)\r\n".utf8))
        response.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
        response.append(Data("Content-Length: \(data.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(data)
        return response
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
