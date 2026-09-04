import Darwin
import Foundation
import M3MCPCore

/// Talks to M3MCPApp over its Unix domain socket.
///
/// The protocol is still HTTP/JSON, but `URLSession` cannot open a Unix socket, so the request is
/// written to the socket directly. Responses use strict `Content-Length` framing, so the client can
/// return as soon as the complete bounded body arrives without trusting the peer to close promptly.
final class LocalAppClient: @unchecked Sendable {
    typealias RegisteredSocketHook = @Sendable (SocketCancellationController) -> Void

    /// Covers the longest accepted provider deadline plus a bounded window for cancellation,
    /// response encoding, and delivery over the local socket.
    static let defaultResponseTimeout = TimeInterval(
        VoiceMemoTranscriptionTimeoutPolicy.transportResponseTimeoutSeconds
    )

    private let socketURL: URL
    private let timeout: TimeInterval
    private let registeredSocketHook: RegisteredSocketHook
    private let queue = DispatchQueue(
        label: "de.markzimmermann.m3mcp.bridge.client",
        attributes: .concurrent
    )

    /// Speech recognition and transcript searches can take minutes; a short timeout would report the
    /// app as unreachable while it is still working.
    init(
        socketURL: URL = M3MCPEndpoint.socketURL,
        timeout: TimeInterval = defaultResponseTimeout,
        registeredSocketHook: @escaping RegisteredSocketHook = { _ in }
    ) {
        self.socketURL = socketURL
        let finiteTimeout = timeout.isFinite ? timeout : Self.defaultResponseTimeout
        self.timeout = min(max(finiteTimeout, 0.001), 86_400)
        self.registeredSocketHook = registeredSocketHook
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

        let cancellationController = SocketCancellationController()

        do {
            let response = try await withTaskCancellationHandler(operation: {
                if Task.isCancelled {
                    cancellationController.cancel()
                }
                return try await send(
                    method: "POST",
                    path: path,
                    body: body,
                    cancellationController: cancellationController
                )
            }, onCancel: {
                cancellationController.cancel()
            })
            return Self.decodeToolResponse(response)
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

    /// Decodes both provider responses and the endpoint's small framing/parser error envelope.
    /// Provider failures intentionally use HTTP 400 with a full `ToolResponse`; transport-level
    /// 4xx errors use `{ "error": ... }` and must not be mislabeled as unreadable JSON.
    static func decodeToolResponse(_ response: LocalHTTPResponse) -> ToolResponse {
        guard (200..<300).contains(response.status) || (400..<500).contains(response.status) else {
            return ToolResponse(
                ok: false,
                source: "M3MCPBridge",
                message: "Local app returned HTTP \(response.status)."
            )
        }

        if let decoded = try? M3JSON.makeDecoder().decode(ToolResponse.self, from: response.body) {
            return decoded
        }

        if response.status >= 400,
           let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
           let error = object["error"] as? String {
            return ToolResponse(
                ok: false,
                source: "M3MCPBridge",
                message: "Local app rejected the request (HTTP \(response.status)): "
                    + M3InputValidation.boundedUTF8Prefix(error, maximumBytes: 600).text
            )
        }

        return ToolResponse(
            ok: false,
            source: "M3MCPBridge",
            message: "Local app returned an unreadable HTTP \(response.status) response."
        )
    }

    // MARK: - Transport

    private typealias HTTPReply = LocalHTTPResponse

    private struct TransportFailure: Error {
        let message: String
    }

    private func send(
        method: String,
        path: String,
        body: Data,
        cancellationController: SocketCancellationController
    ) async throws -> HTTPReply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [socketURL, timeout, cancellationController, registeredSocketHook] in
                do {
                    let reply = try Self.exchange(
                        socketPath: socketURL.path,
                        method: method,
                        path: path,
                        body: body,
                        timeout: timeout,
                        cancellationController: cancellationController,
                        registeredSocketHook: registeredSocketHook
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
        timeout: TimeInterval,
        cancellationController: SocketCancellationController,
        registeredSocketHook: RegisteredSocketHook
    ) throws -> HTTPReply {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TransportFailure(message: "Cannot create a local socket: \(systemMessage(errno)).")
        }
        var registeredForCancellation = false
        defer {
            if registeredForCancellation {
                cancellationController.unregister(descriptor)
            }
            close(descriptor)
        }

        guard cancellationController.register(descriptor) else {
            throw TransportFailure(message: "The local app request was cancelled.")
        }
        registeredForCancellation = true

        let descriptorFlags = fcntl(descriptor, F_GETFL, 0)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFL, descriptorFlags | O_NONBLOCK) == 0 else {
            throw TransportFailure(message: "Cannot configure the local socket for bounded I/O.")
        }

        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let deadline = monotonicDeadline(after: timeout)

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

        guard !cancellationController.isCancelled else {
            throw TransportFailure(message: "The local app request was cancelled.")
        }
        // Test seam for the narrow register -> connect race. Production passes a no-op. A
        // cancellation after the guard can fail to shutdown an as-yet unconnected socket, so the
        // post-connect controller check below is the dispatch authorization boundary.
        registeredSocketHook(cancellationController)
        try connect(
            descriptor,
            to: &address,
            socketPath: socketPath,
            deadline: deadline,
            cancellationController: cancellationController
        )
        guard cancellationController.requestMayBegin(on: descriptor) else {
            throw TransportFailure(message: "The local app request was cancelled before dispatch.")
        }

        var request = Data()
        request.append(Data("\(method) \(path) HTTP/1.1\r\n".utf8))
        request.append(Data("Host: localhost\r\n".utf8))
        request.append(Data("Content-Type: application/json\r\n".utf8))
        request.append(Data("Content-Length: \(body.count)\r\n".utf8))
        request.append(Data("Connection: close\r\n\r\n".utf8))
        request.append(body)

        try writeAll(
            request,
            to: descriptor,
            deadline: deadline,
            cancellationController: cancellationController
        )
        return try readResponse(
            from: descriptor,
            deadline: deadline,
            cancellationController: cancellationController
        )
    }

    private static func connect(
        _ descriptor: Int32,
        to address: inout sockaddr_un,
        socketPath: String,
        deadline: UInt64,
        cancellationController: SocketCancellationController
    ) throws {
        while true {
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    Darwin.connect(
                        descriptor,
                        addressPointer,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            if connected == 0 || errno == EISCONN { return }

            let code = errno
            if code == EINTR { continue }
            guard code == EINPROGRESS || code == EALREADY || code == EWOULDBLOCK else {
                throw TransportFailure(
                    message: "M3MCPApp is not reachable at \(socketPath). Start the macOS app first. (\(systemMessage(code)))"
                )
            }

            _ = try waitForSocket(
                descriptor,
                events: Int16(POLLOUT),
                deadline: deadline,
                cancellationController: cancellationController,
                timeoutMessage: "Connecting to the local app timed out.",
                maximumPollSliceMilliseconds: 100
            )

            var socketError: Int32 = 0
            var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorSize
            ) == 0 else {
                throw TransportFailure(message: "Could not inspect the local socket connection state.")
            }
            if socketError == 0 { return }
            if socketError == EINPROGRESS || socketError == EALREADY { continue }
            throw TransportFailure(
                message: "M3MCPApp is not reachable at \(socketPath). Start the macOS app first. (\(systemMessage(socketError)))"
            )
        }
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        deadline: UInt64,
        cancellationController: SocketCancellationController
    ) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                guard !cancellationController.isCancelled else {
                    throw TransportFailure(message: "The local app request was cancelled while writing.")
                }
                let written = Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset,
                    MSG_DONTWAIT
                )
                if written < 0, errno == EINTR {
                    continue
                }
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    _ = try waitForSocket(
                        descriptor,
                        events: Int16(POLLOUT),
                        deadline: deadline,
                        cancellationController: cancellationController,
                        timeoutMessage: "Writing to the local app exceeded the absolute transport deadline."
                    )
                    continue
                }
                if written <= 0 {
                    throw TransportFailure(message: "Writing to the local socket failed: \(systemMessage(errno)).")
                }
            }
        }
    }

    private static func readResponse(
        from descriptor: Int32,
        deadline: UInt64,
        cancellationController: SocketCancellationController
    ) throws -> LocalHTTPResponse {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            do {
                if let response = try LocalHTTPResponseParser.parseIfComplete(buffer) {
                    return response
                }
            } catch {
                throw malformedResponse(error)
            }

            guard buffer.count < LocalHTTPResponseParser.maximumWireBytes else {
                throw TransportFailure(
                    message: "The local app response exceeded the \(LocalHTTPResponseParser.maximumWireBytes)-byte safety limit."
                )
            }

            _ = try waitForSocket(
                descriptor,
                events: Int16(POLLIN),
                deadline: deadline,
                cancellationController: cancellationController,
                timeoutMessage: "Reading from the local socket failed: the absolute response deadline expired."
            )

            let readCapacity = min(
                chunk.count,
                LocalHTTPResponseParser.maximumWireBytes - buffer.count
            )
            let count = chunk.withUnsafeMutableBytes { raw in
                recv(descriptor, raw.baseAddress, readCapacity, MSG_DONTWAIT)
            }

            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                continue
            }
            if count == 0 {
                do {
                    return try LocalHTTPResponseParser.parse(buffer)
                } catch {
                    throw malformedResponse(error)
                }
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            if count < 0 {
                throw TransportFailure(message: "Reading from the local socket failed: \(systemMessage(errno)).")
            }
        }
    }

    private static func waitForSocket(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64,
        cancellationController: SocketCancellationController,
        timeoutMessage: String,
        maximumPollSliceMilliseconds: Int32? = nil
    ) throws -> Int16 {
        while true {
            guard !cancellationController.isCancelled else {
                throw TransportFailure(message: "The local app request was cancelled.")
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw TransportFailure(message: timeoutMessage) }
            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = max(1, (remainingNanoseconds + 999_999) / 1_000_000)
            var pollMilliseconds = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            if let maximumPollSliceMilliseconds {
                pollMilliseconds = min(pollMilliseconds, maximumPollSliceMilliseconds)
            }

            var readiness = pollfd(
                fd: descriptor,
                events: events | Int16(POLLHUP | POLLERR),
                revents: 0
            )
            let ready = Darwin.poll(&readiness, 1, pollMilliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else {
                throw TransportFailure(message: "Waiting for the local socket failed: \(systemMessage(errno)).")
            }
            if ready == 0 { continue }
            guard readiness.revents & Int16(POLLNVAL) == 0 else {
                throw TransportFailure(message: "The local socket became invalid during transport.")
            }
            guard !cancellationController.isCancelled else {
                throw TransportFailure(message: "The local app request was cancelled.")
            }
            return readiness.revents
        }
    }

    private static func monotonicDeadline(after interval: TimeInterval) -> UInt64 {
        let duration = UInt64(interval * 1_000_000_000)
        let (deadline, overflowed) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(duration)
        return overflowed ? UInt64.max : deadline
    }

    private static func malformedResponse(_ error: Error) -> TransportFailure {
        TransportFailure(
            message: "The local app sent a malformed or oversized HTTP response (\(error))."
        )
    }

    private static func systemMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Owns cancellation access to exactly one live descriptor. The operation remains the sole owner
/// of `close`; cancellation only calls `shutdown` while holding the same lock used to unregister.
/// That prevents a late callback from touching a descriptor number the OS has already reused.
final class SocketCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private var cancelled = false
    private var shutdownIssued = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, self.descriptor == nil else { return false }
        self.descriptor = descriptor
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let descriptor, !shutdownIssued {
            shutdownIssued = true
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        lock.unlock()
    }

    /// Linearization point between a successful connect and the first request byte. Cancellation
    /// before connect may have observed `ENOTCONN`; this locked recheck prevents that failed
    /// shutdown from turning into a later dispatch on the now-connected descriptor.
    func requestMayBegin(on descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.descriptor == descriptor && !cancelled
    }

    func unregister(_ descriptor: Int32) {
        lock.lock()
        if self.descriptor == descriptor {
            self.descriptor = nil
        }
        lock.unlock()
    }
}
