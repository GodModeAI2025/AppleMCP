import Darwin
import Foundation
import M3MCPCore

// Darwin also exports a `flock` record struct, which shadows the BSD `flock(2)` function in
// Swift's module namespace. Bind the libc symbol under an unambiguous Swift name.
@_silgen_name("flock")
private func m3mcpFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Serves the MCP tool endpoint over a Unix domain socket.
///
/// The transport is HTTP so the request shape stays familiar (`curl --unix-socket` still works), but
/// the socket replaces the former loopback TCP port. Access control is now the filesystem's job:
/// the socket lives in a `0700` directory and is itself `0600`, so a sandboxed app — the case macOS
/// TCC is meant to stop — cannot reach it, and neither can a web page.
///
/// The filesystem is only part of the access control, because it stops at the user boundary: every
/// unsandboxed process of the same user could connect and inherit the app's Full Disk Access. So
/// every request other than `GET /health` has to present the capability token, and where the app
/// could work out which binary its bridge is, the connecting process is checked against that
/// binary's code directory hash. `SocketAuthorizer` holds the rules, `PeerIdentity` reads the peer.
final class LocalHTTPServer {
    typealias ToolHandler = (String, [String: JSONValue]) async -> ToolResponse
    /// `includeActivity` is false for the public health probe and true for the diagnostic endpoint.
    typealias StatusHandler = (_ includeActivity: Bool) async -> StatusResponse
    /// Called for every authorization outcome that was refused, so a refusal is visible in the app
    /// rather than silent.
    typealias AuditHandler = @Sendable (AccessAttempt) -> Void

    struct Configuration {
        var requestLimits = LocalHTTPRequestParser.Limits()
        var maximumConcurrentConnections = 16
        /// A pre-existing endpoint is probed before it can be classified as stale and removed.
        /// Keep this short because `start()` holds the endpoint lock for the complete probe.
        var existingSocketProbeDeadline: TimeInterval = 0.25
        /// Absolute monotonic deadline for receiving one complete HTTP request. Unlike a per-read
        /// socket timeout, this also stops a client that continuously trickles a few bytes.
        var requestReadDeadline: TimeInterval = 15
        /// Defence-in-depth ceiling for a single blocked read, not for an async tool operation.
        var readTimeout: TimeInterval = 15
        /// Absolute monotonic deadline for writing one complete HTTP response. This bounds peers
        /// that keep making a little progress and would therefore defeat a per-write timeout.
        var responseWriteDeadline: TimeInterval = 15
        /// Defence-in-depth ceiling for a single blocked socket write. Response writes also use
        /// `responseWriteDeadline`, so this is not the primary progress bound.
        var writeTimeout: TimeInterval = 15
    }

    /// Synchronous syscall boundary for the pre-existing-socket probe. Production uses the live
    /// implementation below; tests inject only outcomes and time so backlog/in-progress paths are
    /// deterministic without depending on kernel backlog sizing.
    struct SocketProbeOperations {
        enum ConnectOutcome {
            case connected
            case pending
            case failed(Int32)
        }

        enum PollOutcome {
            case ready(Int16)
            case timedOut
            case interrupted
            case failed(Int32)
        }

        enum SocketErrorOutcome {
            case value(Int32)
            case failed(Int32)
        }

        var nowNanoseconds: () -> UInt64
        var connect: (_ descriptor: Int32, _ address: inout sockaddr_un) -> ConnectOutcome
        var poll: (_ descriptor: Int32, _ timeoutMilliseconds: Int32) -> PollOutcome
        var socketError: (_ descriptor: Int32) -> SocketErrorOutcome

        static let live = SocketProbeOperations(
            nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            connect: { descriptor, address in
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                        Darwin.connect(
                            descriptor,
                            addressPointer,
                            socklen_t(MemoryLayout<sockaddr_un>.size)
                        )
                    }
                }
                if result == 0 { return .connected }

                let code = errno
                if code == EAGAIN {
                    // Darwin can report a full Unix-socket listen queue as EAGAIN/EWOULDBLOCK. It
                    // is positive evidence of a live listener, so preserve the endpoint.
                    return .connected
                }
                if code == EINPROGRESS || code == EALREADY {
                    return .pending
                }
                if code == EISCONN { return .connected }
                return .failed(code)
            },
            poll: { descriptor, timeoutMilliseconds in
                var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let result = Darwin.poll(&readiness, 1, timeoutMilliseconds)
                if result > 0 { return .ready(readiness.revents) }
                if result == 0 { return .timedOut }
                let code = errno
                return code == EINTR ? .interrupted : .failed(code)
            },
            socketError: { descriptor in
                var value: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                let result = getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    &value,
                    &length
                )
                guard result == 0 else { return .failed(errno) }
                guard length == socklen_t(MemoryLayout<Int32>.size) else {
                    return .failed(EPROTO)
                }
                return .value(value)
            }
        )
    }

    private let socketURL: URL
    private let authorizer: SocketAuthorizer
    private let toolHandler: ToolHandler
    private let statusHandler: StatusHandler
    private let auditHandler: AuditHandler?
    private let acceptQueue = DispatchQueue(label: "de.markzimmermann.m3mcp.accept")
    private let connectionQueue = DispatchQueue(
        label: "de.markzimmermann.m3mcp.connections",
        attributes: .concurrent
    )
    private let parser: LocalHTTPRequestParser
    private let connectionSlots: DispatchSemaphore
    private let activeConnections = ActiveConnectionRegistry()
    private let configuration: Configuration
    private let socketProbeOperations: SocketProbeOperations
    private var acceptSource: DispatchSourceRead?
    private var boundSocketIdentity: (device: dev_t, inode: ino_t)?
    /// Held for the full listener lifetime. `flock` is attached to the opened inode, so the lock
    /// file deliberately remains in place after shutdown; unlinking it could let a third process
    /// create and lock a replacement inode while an already-waiting process still owns the old one.
    private var startLockDescriptor: Int32?

    /// Serializes the tiny race between a peer hangup and attaching the newly-created handler
    /// task. The state owns the task only until the connection thread has observed completion, so
    /// the task and the state cannot retain one another indefinitely.
    private final class RequestCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var task: Task<Void, Never>?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func attach(_ task: Task<Void, Never>) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()

            // A peer can close between monitor startup and task attachment. Cancelling outside the
            // lock avoids invoking arbitrary cancellation handlers while holding shared state.
            if shouldCancel {
                task.cancel()
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }

        func detach() {
            lock.lock()
            task = nil
            lock.unlock()
        }
    }

    /// Tracks descriptor ownership across the accept, request-read, and async-handler phases.
    /// `stop()` only calls `shutdown`; the serving thread remains the sole closer, so a late stop
    /// cannot touch a descriptor number that the OS has already reused.
    private final class ActiveConnectionRegistry: @unchecked Sendable {
        private struct Entry {
            var cancellation: RequestCancellationState?
            var stopped = false
        }

        private let lock = NSLock()
        private var accepting = false
        private var entries: [Int32: Entry] = [:]

        func beginAccepting() {
            lock.lock()
            accepting = true
            lock.unlock()
        }

        func register(_ descriptor: Int32) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard accepting, entries[descriptor] == nil else { return false }
            entries[descriptor] = Entry()
            return true
        }

        func attach(_ cancellation: RequestCancellationState, to descriptor: Int32) {
            lock.lock()
            let shouldCancel: Bool
            if var entry = entries[descriptor] {
                entry.cancellation = cancellation
                entries[descriptor] = entry
                shouldCancel = entry.stopped
            } else {
                shouldCancel = true
            }
            lock.unlock()

            if shouldCancel {
                cancellation.cancel()
            }
        }

        func unregister(_ descriptor: Int32) {
            lock.lock()
            entries.removeValue(forKey: descriptor)
            lock.unlock()
        }

        func stopAll() {
            lock.lock()
            accepting = false
            let descriptors = Array(entries.keys)
            let cancellations = descriptors.map { descriptor -> RequestCancellationState? in
                var entry = entries[descriptor] ?? Entry()
                entry.stopped = true
                entries[descriptor] = entry
                // Keep the ownership lock through shutdown. The serving thread unregisters under
                // this same lock before closing, so the descriptor number cannot be recycled in
                // the gap between validation and this syscall.
                _ = Darwin.shutdown(descriptor, SHUT_RDWR)
                return entry.cancellation
            }
            lock.unlock()

            // Framework cancellation can synchronously call arbitrary handlers. Invoke it only
            // after releasing the descriptor-ownership lock.
            for cancellation in cancellations {
                cancellation?.cancel()
            }
        }
    }

    /// Watches an already-framed, one-request connection for peer closure without consuming any
    /// bytes. Read readiness is checked with `MSG_PEEK`: EOF cancels the handler; post-request bytes
    /// are a protocol violation and also cancel it. Cancelling the source and waiting for its cancel
    /// handler before closing the descriptor prevents a late callback from observing a reused fd.
    private final class PeerDisconnectMonitor: @unchecked Sendable {
        private let descriptor: Int32
        private let source: DispatchSourceRead
        private let quiesced = DispatchSemaphore(value: 0)
        private let onDisconnect: @Sendable () -> Void

        init(descriptor: Int32, onDisconnect: @escaping @Sendable () -> Void) {
            self.descriptor = descriptor
            self.onDisconnect = onDisconnect

            let queue = DispatchQueue(
                label: "de.markzimmermann.m3mcp.peer-monitor.\(descriptor)",
                qos: .userInitiated
            )
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            self.source = source
            source.setEventHandler { [weak self] in
                self?.handleReadReadiness()
            }
            source.setCancelHandler { [quiesced] in
                quiesced.signal()
            }
        }

        func start() {
            source.resume()
        }

        func stopAndWait() {
            source.cancel()
            quiesced.wait()
        }

        private func handleReadReadiness() {
            var byte: UInt8 = 0
            let result = withUnsafeMutablePointer(to: &byte) { pointer in
                Darwin.recv(descriptor, pointer, 1, MSG_PEEK | MSG_DONTWAIT)
            }

            if result == 0 || result > 0 {
                // Zero is EOF. A positive result is data beyond the single framed request. Either
                // way this connection must no longer authorize work, and MSG_PEEK left the byte in
                // the socket buffer.
                onDisconnect()
                source.cancel()
                return
            }

            let code = errno
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                return
            }

            // Reset, not-connected, or an unexpected descriptor error are all fail-closed.
            onDisconnect()
            source.cancel()
        }
    }

    /// `authorizer` has no default on purpose. A default that let the endpoint answer without a
    /// token would be one forgotten argument away from putting the socket back where it was.
    init(
        socketURL: URL,
        authorizer: SocketAuthorizer,
        configuration: Configuration = Configuration(),
        socketProbeOperations: SocketProbeOperations = .live,
        toolHandler: @escaping ToolHandler,
        statusHandler: @escaping StatusHandler,
        auditHandler: AuditHandler? = nil
    ) {
        self.socketURL = socketURL
        self.authorizer = authorizer
        self.configuration = configuration
        self.socketProbeOperations = socketProbeOperations
        self.parser = LocalHTTPRequestParser(limits: configuration.requestLimits)
        self.connectionSlots = DispatchSemaphore(value: max(1, configuration.maximumConcurrentConnections))
        self.toolHandler = toolHandler
        self.statusHandler = statusHandler
        self.auditHandler = auditHandler
    }

    deinit {
        // Normally the app stops explicitly. Keep descriptor and pathname ownership safe if a
        // partially-initialized host instead releases its server during an error or teardown.
        stop()
    }

    struct StartFailure: LocalizedError {
        let message: String

        var errorDescription: String? { message }

        init(_ message: String, errno code: Int32? = nil) {
            if let code {
                self.message = "\(message): \(String(cString: strerror(code)))"
            } else {
                self.message = message
            }
        }
    }

    static func startLockURL(for socketURL: URL) -> URL {
        socketURL.appendingPathExtension("start.lock")
    }

    // MARK: - Lifecycle

    func start() throws {
        guard acceptSource == nil else {
            return
        }

        let path = socketURL.path
        guard path.utf8.count <= M3MCPEndpoint.maximumSocketPathLength else {
            throw StartFailure("Socket path is too long for a Unix domain socket: \(path)")
        }

        try prepareDirectory()

        // `lstat -> connect -> unlink -> bind` cannot by itself be made atomic. Serialize that
        // complete sequence across processes with a private, endpoint-specific advisory lock.
        // The descriptor is retained through stop(), which also covers the interval in which the
        // pathname is removed while the cancelled DispatchSource is still closing its listener.
        let acquiredStartLock = try acquireStartLock()
        var retainStartLock = false
        defer {
            if !retainStartLock {
                releaseStartLock(acquiredStartLock)
            }
        }

        // Remove only an owned, stale socket. A live instance or a non-socket path must never be
        // replaced merely because it occupies the configured filename.
        try prepareSocketPath(path)

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
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw StartFailure("Cannot secure socket permissions for \(path)", errno: code)
        }

        var socketMetadata = stat()
        guard lstat(path, &socketMetadata) == 0,
              socketMetadata.st_uid == getuid(),
              socketMetadata.st_mode & S_IFMT == S_IFSOCK else {
            close(descriptor)
            unlink(path)
            throw StartFailure("Bound socket did not have the expected owner and file type")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            // Capture the immutable descriptor owned by this source. Reading a mutable server
            // property here would race start/stop and could accept on a recycled descriptor.
            self?.acceptPendingConnections(on: descriptor)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        boundSocketIdentity = (socketMetadata.st_dev, socketMetadata.st_ino)
        acceptSource = source
        startLockDescriptor = acquiredStartLock
        retainStartLock = true
        activeConnections.beginAccepting()
        source.resume()
    }

    func stop() {
        // Mark admission closed before cancelling the listener. An accept callback already in
        // progress will then reject its client, while shutdown wakes every registered read/write
        // and cancellation reaches any attached async handler.
        activeConnections.stopAll()
        acceptSource?.cancel()
        acceptSource = nil
        removeBoundSocket()
        if let descriptor = startLockDescriptor {
            startLockDescriptor = nil
            releaseStartLock(descriptor)
        }
    }

    private func prepareDirectory() throws {
        let directory = socketURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        do {
            var metadata = stat()
            if lstat(directory.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw StartFailure("Socket directory is not a real directory: \(directory.path)")
                }
                guard metadata.st_uid == getuid() else {
                    throw StartFailure("Socket directory is not owned by the current user: \(directory.path)")
                }
                guard chmod(directory.path, 0o700) == 0 else {
                    throw StartFailure("Cannot secure socket directory \(directory.path)", errno: errno)
                }
            } else if errno == ENOENT {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } else {
                throw StartFailure("Cannot inspect socket directory \(directory.path)", errno: errno)
            }
        } catch {
            if let failure = error as? StartFailure {
                throw failure
            }
            throw StartFailure("Cannot prepare \(directory.path): \(error.localizedDescription)")
        }
    }

    private func prepareSocketPath(_ path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw StartFailure("Cannot inspect existing socket path \(path)", errno: errno)
        }

        guard metadata.st_uid == getuid() else {
            throw StartFailure("Existing socket path is not owned by the current user: \(path)")
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK else {
            throw StartFailure("Refusing to replace a non-socket path at \(path)")
        }
        if try socketAcceptsConnections(at: path) {
            throw StartFailure("Another M3MCP-compatible server is already listening at \(path)")
        }

        // The probe can release the CPU while polling. Even inside the cooperative start lock,
        // re-check the pathname identity before unlinking so a non-cooperating same-user process
        // cannot make us remove a replacement listener.
        var verifiedMetadata = stat()
        guard lstat(path, &verifiedMetadata) == 0 else {
            if errno == ENOENT { return }
            throw StartFailure("Cannot re-inspect stale socket at \(path)", errno: errno)
        }
        guard verifiedMetadata.st_uid == metadata.st_uid,
              verifiedMetadata.st_mode & S_IFMT == S_IFSOCK,
              verifiedMetadata.st_dev == metadata.st_dev,
              verifiedMetadata.st_ino == metadata.st_ino else {
            throw StartFailure("Existing socket changed while it was being probed at \(path)")
        }
        guard unlink(path) == 0 else {
            throw StartFailure("Cannot remove stale socket at \(path)", errno: errno)
        }
    }

    private func acquireStartLock() throws -> Int32 {
        let lockURL = Self.startLockURL(for: socketURL)
        let lockPath = lockURL.path
        let descriptor = Darwin.open(
            lockPath,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw StartFailure("Cannot open endpoint start lock at \(lockPath)", errno: errno)
        }

        var descriptorMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw StartFailure("Cannot inspect endpoint start lock at \(lockPath)", errno: code)
        }
        guard descriptorMetadata.st_uid == getuid(),
              descriptorMetadata.st_mode & S_IFMT == S_IFREG,
              descriptorMetadata.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw StartFailure(
                "Endpoint start lock must be a singly-linked regular file owned by the current user: \(lockPath)"
            )
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw StartFailure("Cannot secure endpoint start lock at \(lockPath)", errno: code)
        }

        guard m3mcpFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw StartFailure(
                    "Another M3MCP server is starting or running for endpoint \(socketURL.path)"
                )
            }
            throw StartFailure("Cannot acquire endpoint start lock at \(lockPath)", errno: code)
        }

        // Opening with O_NOFOLLOW protects the final component. Re-check the pathname after the
        // lock is acquired so a replacement during open/acquire is detected before any socket
        // inspection or unlink. The 0700 parent directory excludes other users entirely.
        var pathMetadata = stat()
        let pathStatus = lstat(lockPath, &pathMetadata)
        let pathError = pathStatus == 0 ? nil : errno
        guard pathStatus == 0,
              pathMetadata.st_uid == getuid(),
              pathMetadata.st_mode & S_IFMT == S_IFREG,
              pathMetadata.st_nlink == 1,
              pathMetadata.st_dev == descriptorMetadata.st_dev,
              pathMetadata.st_ino == descriptorMetadata.st_ino else {
            releaseStartLock(descriptor)
            throw StartFailure(
                "Endpoint start lock changed while it was being acquired at \(lockPath)",
                errno: pathError
            )
        }

        return descriptor
    }

    private func releaseStartLock(_ descriptor: Int32) {
        // Closing is the authoritative release. An explicit unlock makes the ownership transition
        // easy to audit, and no lock-file unlink is performed (see `startLockDescriptor`).
        _ = m3mcpFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private func socketAcceptsConnections(at path: String) throws -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw StartFailure("Cannot create socket probe", errno: errno) }
        defer { close(probe) }

        let flags = fcntl(probe, F_GETFL, 0)
        guard flags >= 0, fcntl(probe, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw StartFailure("Cannot make socket probe nonblocking", errno: errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, path, capacity)
            }
        }
        switch socketProbeOperations.connect(probe, &address) {
        case .connected:
            return true
        case let .failed(code):
            return try classifySocketProbeError(code, at: path)
        case .pending:
            return try waitForSocketProbeConnection(probe, at: path)
        }
    }

    private func waitForSocketProbeConnection(_ descriptor: Int32, at path: String) throws -> Bool {
        let interval = configuration.existingSocketProbeDeadline
        guard interval.isFinite, interval > 0, interval <= 5 else {
            throw StartFailure("Existing-socket probe deadline must be positive, finite, and at most five seconds")
        }

        let duration = UInt64((interval * 1_000_000_000).rounded(.up))
        let started = socketProbeOperations.nowNanoseconds()
        let (candidateDeadline, overflowed) = started.addingReportingOverflow(duration)
        let deadline = overflowed ? UInt64.max : candidateDeadline

        while true {
            let now = socketProbeOperations.nowNanoseconds()
            guard now < deadline else {
                throw socketProbeTimeout(at: path)
            }

            let remaining = deadline - now
            let wholeMilliseconds = remaining / 1_000_000
            let roundedMilliseconds = wholeMilliseconds + (remaining % 1_000_000 == 0 ? 0 : 1)
            let pollTimeout = Int32(min(max(roundedMilliseconds, 1), UInt64(Int32.max)))

            switch socketProbeOperations.poll(descriptor, pollTimeout) {
            case .timedOut:
                // `poll` returning zero means its supplied remaining-deadline interval elapsed.
                // Treat it as an expired absolute deadline even if an injected/test clock did not
                // advance, rather than allowing a malformed clock seam to spin under the lock.
                throw socketProbeTimeout(at: path)
            case .interrupted:
                continue
            case let .failed(code):
                throw StartFailure("Cannot wait for existing socket probe", errno: code)
            case let .ready(events):
                if events & Int16(POLLNVAL) != 0 {
                    throw StartFailure("Existing socket probe descriptor became invalid")
                }
                guard events & Int16(POLLOUT | POLLERR | POLLHUP) != 0 else {
                    throw StartFailure("Existing socket probe returned unexpected poll events")
                }

                switch socketProbeOperations.socketError(descriptor) {
                case let .failed(code):
                    throw StartFailure("Cannot inspect existing socket probe state", errno: code)
                case let .value(code):
                    if code == 0 {
                        guard events & Int16(POLLOUT) != 0 else {
                            // HUP/ERR without a socket error is ambiguous. Preserve the endpoint.
                            throw StartFailure("Existing socket probe completed ambiguously")
                        }
                        return true
                    }
                    if code == EAGAIN { return true }
                    if code == EINPROGRESS || code == EALREADY {
                        continue
                    }
                    return try classifySocketProbeError(code, at: path)
                }
            }
        }
    }

    private func classifySocketProbeError(_ code: Int32, at path: String) throws -> Bool {
        if code == ECONNREFUSED || code == ENOENT { return false }
        if code == EISCONN { return true }
        throw StartFailure("Cannot verify whether existing socket is stale at \(path)", errno: code)
    }

    private func socketProbeTimeout(at path: String) -> StartFailure {
        StartFailure("Timed out verifying existing socket at \(path); refusing to replace it")
    }

    private func removeBoundSocket() {
        guard let expected = boundSocketIdentity else { return }
        defer { boundSocketIdentity = nil }

        var metadata = stat()
        guard lstat(socketURL.path, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_dev == expected.device,
              metadata.st_ino == expected.inode else {
            return
        }
        unlink(socketURL.path)
    }

    // MARK: - Accepting

    private func acceptPendingConnections(on listeningDescriptor: Int32) {
        while true {
            let client = accept(listeningDescriptor, nil, nil)
            guard client >= 0 else {
                return
            }

            // Without this a client that hangs up mid-response would kill the app with SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            // Darwin does not pass O_NONBLOCK on to accepted sockets. Keep the descriptor blocking
            // for its socket-level defence-in-depth timeouts; bounded response writes use
            // `MSG_DONTWAIT` and `poll` below.
            let clientFlags = fcntl(client, F_GETFL, 0)
            if clientFlags >= 0 {
                _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
            }

            guard configureTimeouts(on: client) else {
                close(client)
                continue
            }

            // Admission is deliberately non-blocking so slow clients cannot stall the accept loop.
            // A slot is held through a long-running tool call, but the socket timeouts only cover
            // individual I/O operations; transcription and other legitimate work remain unbounded.
            guard connectionSlots.wait(timeout: .now()) == .success else {
                rejectOverloaded(client)
                continue
            }

            guard activeConnections.register(client) else {
                connectionSlots.signal()
                close(client)
                continue
            }

            connectionQueue.async { [self] in
                defer {
                    // Unregister while this thread still owns an open descriptor; only then close
                    // it, preventing stop() from racing with descriptor-number reuse.
                    activeConnections.unregister(client)
                    close(client)
                    connectionSlots.signal()
                }
                serve(client)
            }
        }
    }

    private func configureTimeouts(on client: Int32) -> Bool {
        var readWindow = socketTimeout(configuration.readTimeout)
        guard setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &readWindow,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            return false
        }

        var writeWindow = socketTimeout(configuration.writeTimeout)
        return setsockopt(
            client,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &writeWindow,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0
    }

    private func socketTimeout(_ interval: TimeInterval) -> timeval {
        let clamped = boundedIOInterval(interval)
        let wholeSeconds = clamped.rounded(.down)
        let microseconds = (clamped - wholeSeconds) * 1_000_000
        let boundedMicroseconds = min(max(Int(microseconds.rounded(.down)), 0), 999_999)
        return timeval(tv_sec: Int(wholeSeconds), tv_usec: Int32(boundedMicroseconds))
    }

    private func boundedIOInterval(_ interval: TimeInterval) -> TimeInterval {
        let finiteInterval = interval.isFinite ? interval : 15
        // Socket I/O should never legitimately block for more than a day. A concrete finite cap also
        // makes conversion to `timeval` safe for injected configurations such as `Double.greatestFiniteMagnitude`.
        return min(max(finiteInterval, 0.001), 86_400)
    }

    private func monotonicDeadline(after interval: TimeInterval) -> UInt64 {
        let duration = UInt64(boundedIOInterval(interval) * 1_000_000_000)
        let (deadline, overflowed) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(duration)
        return overflowed ? UInt64.max : deadline
    }

    private func rejectOverloaded(_ client: Int32) {
        let response = makeResponse(
            status: 503,
            data: encodedError("Local endpoint is at its connection limit. Try again shortly.")
        )

        // The accept queue must never wait for an already-overloaded client. A fresh local socket
        // normally accepts this small response immediately; if it stops accepting bytes, closing it
        // is the safe fallback.
        response.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(
                    client,
                    base.advanced(by: offset),
                    raw.count - offset,
                    MSG_DONTWAIT
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    return
                }
                offset += written
            }
        }
        close(client)
    }

    private func serve(_ client: Int32) {
        switch readRequest(from: client) {
        case .request(let request):
            // The peer is read here and not at `accept`: resolving it costs a signature check, and a
            // connection that never delivered a request never reaches an authorization decision.
            // The descriptor is still the one the peer connected on, so `LOCAL_PEERTOKEN` names the
            // process that opened it.
            let peer = PeerIdentity.resolve(descriptor: client)

            // Once framing is complete no more client bytes are expected. Keep watching the read
            // side while the async handler runs so a bridge cancellation (`shutdown`) or crashed
            // client promptly cancels the work and returns the connection slot.
            let done = DispatchSemaphore(value: 0)
            let cancellation = RequestCancellationState()
            activeConnections.attach(cancellation, to: client)
            let monitor = PeerDisconnectMonitor(descriptor: client) {
                cancellation.cancel()
            }
            monitor.start()

            let task = Task { [weak self] in
                defer { done.signal() }
                await self?.respond(to: request, on: client, peer: peer, cancellation: cancellation)
            }
            cancellation.attach(task)
            done.wait()
            cancellation.detach()
            monitor.stopAndWait()
        case .tooLarge(.headers):
            send(status: 431, body: ["error": "Request headers are too large."], to: client)
        case .tooLarge(.body):
            send(status: 413, body: ["error": "Request body is too large."], to: client)
        case .malformed(let reason):
            send(status: 400, body: ["error": reason.clientMessage], to: client)
        case .timedOut:
            send(status: 408, body: ["error": "Timed out while reading the request."], to: client)
        case .failed:
            send(status: 400, body: ["error": "Could not read a complete request."], to: client)
        }
    }

    private enum ReadOutcome {
        case request(LocalHTTPRequest)
        case tooLarge(LocalHTTPRequestParser.TooLargeReason)
        case malformed(LocalHTTPRequestParser.MalformedReason)
        case timedOut
        case failed
    }

    private func readRequest(from client: Int32) -> ReadOutcome {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1_024)
        let maximumBufferedBytes = parser.limits.maximumBufferedBytes
        let deadline = monotonicDeadline(after: configuration.requestReadDeadline)

        while true {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                return .timedOut
            }
            switch parser.parse(buffer) {
            case .complete(let request):
                return .request(request)
            case .malformed(let reason):
                return .malformed(reason)
            case .tooLarge(let reason):
                return .tooLarge(reason)
            case .incomplete:
                break
            }

            guard buffer.count < maximumBufferedBytes else {
                return .tooLarge(.body)
            }
            let remainingCapacity = maximumBufferedBytes - buffer.count
            let readCapacity = min(chunk.count, remainingCapacity)
            guard readCapacity > 0 else {
                return .tooLarge(.body)
            }

            let current = DispatchTime.now().uptimeNanoseconds
            guard current < deadline else {
                return .timedOut
            }
            let remainingNanoseconds = deadline - current
            let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
            let pollMilliseconds = Int32(min(roundedMilliseconds, UInt64(Int32.max)))

            var readiness = pollfd(
                fd: client,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let ready = Darwin.poll(&readiness, 1, pollMilliseconds)
            if ready == 0 {
                return .timedOut
            }
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                return .failed
            }
            if readiness.revents & Int16(POLLNVAL) != 0 {
                return .failed
            }

            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(client, base, readCapacity, MSG_DONTWAIT)
            }

            if count == 0 {
                return .failed
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                return .failed
            }

            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// Kept from the loopback era as defence in depth.
    ///
    /// A browser cannot open a Unix socket at all, so these checks should never fire now. They cost
    /// nothing, and they keep the endpoint honest if the transport ever changes back.
    private enum RequestGuard {
        /// Present only on browser-issued requests.
        static let browserOnlyHeaders = ["origin", "referer", "sec-fetch-site", "sec-fetch-mode"]

        /// Returns a rejection reason, or nil when the request is acceptable.
        static func rejection(for request: LocalHTTPRequest) -> String? {
            for header in browserOnlyHeaders where request.headers[header] != nil {
                return "Requests carrying '\(header)' are refused: this endpoint is not reachable from a browser."
            }

            // Enforced on tool calls only, so /health stays trivially checkable.
            if request.method == "POST", request.path.hasPrefix("/tools/") {
                let contentType = request.headers["content-type"] ?? ""
                let mediaType = contentType
                    .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard mediaType == "application/json" else {
                    return "Tool calls require Content-Type: application/json."
                }
            }

            return nil
        }
    }

    // MARK: - Responding

    private func respond(
        to request: LocalHTTPRequest,
        on client: Int32,
        peer: PeerIdentity,
        cancellation: RequestCancellationState
    ) async {
        guard responseIsAllowed(cancellation) else { return }

        if let reason = RequestGuard.rejection(for: request) {
            report(request, peer: peer, allowed: false, reason: reason)
            send(status: 403, refusal: reason, path: request.path, to: client, cancellation: cancellation)
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
            send(status: status, refusal: reason, path: request.path, to: client, cancellation: cancellation)
            return
        }

        report(request, peer: peer, allowed: true, reason: nil)

        if request.method == "GET", request.path == "/health" {
            let status = await statusHandler(false)
            guard responseIsAllowed(cancellation) else { return }
            send(status: 200, codable: status, to: client, cancellation: cancellation)
            return
        }

        if request.method == "GET", request.path == "/status" {
            let status = await statusHandler(true)
            guard responseIsAllowed(cancellation) else { return }
            send(status: 200, codable: status, to: client, cancellation: cancellation)
            return
        }

        if request.method == "POST", request.path.hasPrefix("/tools/") {
            let tool = String(request.path.dropFirst("/tools/".count)).removingPercentEncoding ?? ""
            guard let input = LocalToolInputDecoder.decode(request.body) else {
                send(
                    status: 400,
                    body: ["error": "Request body must be a valid JSON object."],
                    to: client,
                    cancellation: cancellation
                )
                return
            }
            let response = await toolHandler(tool, input)
            guard responseIsAllowed(cancellation) else { return }
            send(
                status: response.ok ? 200 : 400,
                codable: response,
                to: client,
                cancellation: cancellation
            )
            return
        }

        send(status: 404, body: ["error": "Not found"], to: client, cancellation: cancellation)
    }

    private func report(_ request: LocalHTTPRequest, peer: PeerIdentity, allowed: Bool, reason: String?) {
        guard let auditHandler else { return }
        auditHandler(
            AccessAttempt(
                method: request.method,
                path: request.path,
                peer: peer,
                allowed: allowed,
                reason: reason
            )
        )
    }

    /// A refusal on a tool path has to decode as a `ToolResponse`, because that is the only shape
    /// `LocalAppClient` reads for statuses in `200..<500`; anything else reaches the MCP client as
    /// "unreadable response" instead of as the reason it was refused.
    private func send(
        status: Int,
        refusal: String,
        path: String,
        to client: Int32,
        cancellation: RequestCancellationState? = nil
    ) {
        if path.hasPrefix("/tools/") {
            send(
                status: status,
                codable: ToolResponse(ok: false, source: "M3MCP Server", message: refusal),
                to: client,
                cancellation: cancellation
            )
        } else {
            send(status: status, body: ["error": refusal], to: client, cancellation: cancellation)
        }
    }

    private func responseIsAllowed(_ cancellation: RequestCancellationState?) -> Bool {
        !Task.isCancelled && cancellation?.isCancelled != true
    }

    private func send<T: Encodable>(
        status: Int,
        codable: T,
        to client: Int32,
        cancellation: RequestCancellationState? = nil
    ) {
        guard responseIsAllowed(cancellation) else { return }
        let data: Data
        do {
            data = try M3JSON.makeEncoder().encode(codable)
        } catch {
            send(
                status: 500,
                body: ["error": error.localizedDescription],
                to: client,
                cancellation: cancellation
            )
            return
        }

        send(status: status, data: data, to: client, cancellation: cancellation)
    }

    private func send(
        status: Int,
        body: [String: String],
        to client: Int32,
        cancellation: RequestCancellationState? = nil
    ) {
        guard responseIsAllowed(cancellation) else { return }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? encodedError("Internal server error.")
        send(status: status, data: data, to: client, cancellation: cancellation)
    }

    private func send(
        status: Int,
        data: Data,
        to client: Int32,
        cancellation: RequestCancellationState? = nil
    ) {
        guard responseIsAllowed(cancellation) else { return }
        let responseStatus: Int
        let responseData: Data
        if data.count > LocalHTTPResponseParser.maximumBodyBytes {
            // The bridge rejects bodies above this shared limit. Fail centrally with a small,
            // parseable response instead of reporting provider success while writing a response
            // that the only client must discard as malformed/oversized.
            responseStatus = 413
            responseData = encodedError(
                "Encoded local response exceeds the \(LocalHTTPResponseParser.maximumBodyBytes)-byte transport limit. Narrow the request."
            )
        } else {
            responseStatus = status
            responseData = data
        }
        writeAll(
            makeResponse(status: responseStatus, data: responseData),
            to: client,
            cancellation: cancellation
        )
    }

    private func encodedError(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private func makeResponse(status: Int, data: Data) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 408: reason = "Request Timeout"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
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

    @discardableResult
    private func writeAll(
        _ data: Data,
        to client: Int32,
        cancellation: RequestCancellationState? = nil
    ) -> Bool {
        // MSG_DONTWAIT is retained on each send for clarity, but mark the descriptor itself
        // nonblocking too: no platform-specific stream-send behavior may enter a blocking syscall
        // and bypass the absolute poll deadline. The descriptor is connection-local and closes
        // immediately after this response, so there is no mode to restore.
        let flags = fcntl(client, F_GETFL, 0)
        guard flags >= 0, fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0 else {
            _ = Darwin.shutdown(client, SHUT_RDWR)
            return false
        }

        let deadline = monotonicDeadline(after: configuration.responseWriteDeadline)
        let completed = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                guard responseIsAllowed(cancellation),
                      DispatchTime.now().uptimeNanoseconds < deadline else {
                    return false
                }

                let written = Darwin.send(
                    client,
                    base.advanced(by: offset),
                    raw.count - offset,
                    MSG_DONTWAIT
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    return false
                }

                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                let remainingNanoseconds = deadline - now
                let roundedMilliseconds = max(1, (remainingNanoseconds + 999_999) / 1_000_000)
                var readiness = pollfd(
                    fd: client,
                    // POLLIN also wakes a blocked response when the peer disconnect monitor has
                    // observed EOF or forbidden bytes after the single framed request.
                    events: Int16(POLLOUT | POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let ready = Darwin.poll(
                    &readiness,
                    1,
                    Int32(min(roundedMilliseconds, UInt64(Int32.max)))
                )
                if ready < 0, errno == EINTR { continue }
                guard ready > 0,
                      readiness.revents & Int16(POLLNVAL | POLLHUP | POLLERR) == 0,
                      readiness.revents & Int16(POLLIN) == 0,
                      responseIsAllowed(cancellation) else {
                    return false
                }
            }
            return true
        }

        guard completed else {
            // The serving thread remains the sole descriptor closer. Shutdown fails the response
            // immediately and wakes the peer monitor; the existing defer then unregisters, closes,
            // and releases the connection slot without risking descriptor reuse.
            _ = Darwin.shutdown(client, SHUT_RDWR)
            return false
        }
        return true
    }
}
