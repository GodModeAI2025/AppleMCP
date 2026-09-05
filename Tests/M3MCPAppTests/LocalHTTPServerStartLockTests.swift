import Darwin
import Foundation
import M3MCPCore
import XCTest
@testable import M3MCPApp

final class LocalHTTPServerStartLockTests: XCTestCase {
    func testConcurrentStartsAgainstAStaleSocketElectExactlyOneOwner() throws {
        let directory = try makeTemporaryDirectory(prefix: "m3-lock-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")

        try createStaleSocket(at: socketURL)
        var staleMetadata = stat()
        XCTAssertEqual(lstat(socketURL.path, &staleMetadata), 0)
        XCTAssertEqual(staleMetadata.st_mode & S_IFMT, S_IFSOCK)

        let servers = [makeServer(at: socketURL), makeServer(at: socketURL)]
        defer { servers.forEach { $0.stop() } }

        let ready = DispatchGroup()
        let finished = DispatchGroup()
        let startGate = DispatchSemaphore(value: 0)
        let results = LockedStartResults()
        let queue = DispatchQueue(
            label: "de.markzimmermann.m3mcp.tests.start-lock-race",
            attributes: .concurrent
        )

        for (index, server) in servers.enumerated() {
            ready.enter()
            finished.enter()
            queue.async {
                ready.leave()
                startGate.wait()
                do {
                    try server.start()
                    results.recordSuccess(index)
                } catch {
                    results.recordFailure(error.localizedDescription)
                }
                finished.leave()
            }
        }

        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        startGate.signal()
        startGate.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(results.successes.count, 1)
        XCTAssertEqual(results.failures.count, 1)
        XCTAssertTrue(try XCTUnwrap(results.failures.first).contains("starting or running"))

        // The losing starter must not unlink the winner's freshly-bound pathname.
        var liveMetadata = stat()
        XCTAssertEqual(lstat(socketURL.path, &liveMetadata), 0)
        XCTAssertEqual(liveMetadata.st_mode & S_IFMT, S_IFSOCK)
        let client = try connect(to: socketURL)
        Darwin.close(client)
    }

    func testStartLockIsPrivatePersistentAndReleasedByStop() throws {
        let directory = try makeTemporaryDirectory(prefix: "m3-lock-mode")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")
        let lockURL = LocalHTTPServer.startLockURL(for: socketURL)

        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))
        XCTAssertEqual(chmod(lockURL.path, 0o666), 0)

        let first = makeServer(at: socketURL)
        let second = makeServer(at: socketURL)
        defer {
            first.stop()
            second.stop()
        }

        try first.start()
        var firstLockMetadata = stat()
        XCTAssertEqual(lstat(lockURL.path, &firstLockMetadata), 0)
        XCTAssertEqual(firstLockMetadata.st_uid, getuid())
        XCTAssertEqual(firstLockMetadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(firstLockMetadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(firstLockMetadata.st_nlink, 1)

        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("starting or running"))
        }

        first.stop()
        try second.start()

        // Keeping the inode in place is required for flock correctness when contenders already
        // opened it. Shutdown releases the descriptor but intentionally does not unlink the file.
        var secondLockMetadata = stat()
        XCTAssertEqual(lstat(lockURL.path, &secondLockMetadata), 0)
        XCTAssertEqual(secondLockMetadata.st_dev, firstLockMetadata.st_dev)
        XCTAssertEqual(secondLockMetadata.st_ino, firstLockMetadata.st_ino)
        XCTAssertEqual(secondLockMetadata.st_mode & 0o777, 0o600)
        let client = try connect(to: socketURL)
        Darwin.close(client)
    }

    func testFailureAfterLockAcquisitionReleasesLockForNextStarter() throws {
        let directory = try makeTemporaryDirectory(prefix: "m3-lock-error")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: socketURL.path,
                contents: Data("do-not-replace".utf8)
            )
        )

        let failing = makeServer(at: socketURL)
        XCTAssertThrowsError(try failing.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("non-socket path"))
        }
        XCTAssertEqual(try Data(contentsOf: socketURL), Data("do-not-replace".utf8))

        try FileManager.default.removeItem(at: socketURL)
        let succeeding = makeServer(at: socketURL)
        defer { succeeding.stop() }
        try succeeding.start()
        let client = try connect(to: socketURL)
        Darwin.close(client)
    }

    func testDeinitializationPerformsTheSameLockAndSocketCleanupAsStop() throws {
        let directory = try makeTemporaryDirectory(prefix: "m3-lock-deinit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")

        var server: LocalHTTPServer? = makeServer(at: socketURL)
        try server?.start()
        var socketMetadata = stat()
        XCTAssertEqual(lstat(socketURL.path, &socketMetadata), 0)

        server = nil

        let replacement = makeServer(at: socketURL)
        defer { replacement.stop() }
        try replacement.start()
        let client = try connect(to: socketURL)
        Darwin.close(client)
    }

    func testSymlinkStartLockIsRejectedWithoutTouchingItsTarget() throws {
        let directory = try makeTemporaryDirectory(prefix: "m3-lock-link")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")
        let lockURL = LocalHTTPServer.startLockURL(for: socketURL)
        let targetURL = directory.appendingPathComponent("target.txt")
        let sentinel = Data("sentinel".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: targetURL.path, contents: sentinel))
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: targetURL)

        let server = makeServer(at: socketURL)
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Cannot open endpoint start lock"))
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), sentinel)
        var socketMetadata = stat()
        let socketStatus = lstat(socketURL.path, &socketMetadata)
        let socketError = errno
        XCTAssertEqual(socketStatus, -1)
        XCTAssertEqual(socketError, ENOENT)
    }

    func testLiveSocketProbePreservesExternallyOwnedListener() throws {
        let directory = try makeTemporaryDirectory(prefix: "m3-probe-live")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")
        let listener = try createListeningSocket(at: socketURL)
        defer { Darwin.close(listener) }

        var originalMetadata = stat()
        XCTAssertEqual(lstat(socketURL.path, &originalMetadata), 0)
        let server = makeServer(at: socketURL)
        defer { server.stop() }

        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("already listening"))
        }
        var preservedMetadata = stat()
        XCTAssertEqual(lstat(socketURL.path, &preservedMetadata), 0)
        XCTAssertEqual(preservedMetadata.st_dev, originalMetadata.st_dev)
        XCTAssertEqual(preservedMetadata.st_ino, originalMetadata.st_ino)
    }

    func testPendingProbeTimeoutIsBoundedAndPreservesExistingListener() throws {
        let directory = try makeTemporaryDirectory(prefix: "m3-probe-timeout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")
        let listener = try createListeningSocket(at: socketURL)
        defer { Darwin.close(listener) }

        var originalMetadata = stat()
        XCTAssertEqual(lstat(socketURL.path, &originalMetadata), 0)

        var configuration = LocalHTTPServer.Configuration()
        configuration.existingSocketProbeDeadline = 0.05
        var observedPollTimeouts: [Int32] = []
        let operations = LocalHTTPServer.SocketProbeOperations(
            nowNanoseconds: { 1_000_000 },
            connect: { _, _ in .pending },
            poll: { _, timeoutMilliseconds in
                observedPollTimeouts.append(timeoutMilliseconds)
                return .timedOut
            },
            socketError: { _ in
                XCTFail("A timed-out poll must not inspect SO_ERROR")
                return .failed(EIO)
            }
        )
        let server = makeServer(
            at: socketURL,
            configuration: configuration,
            socketProbeOperations: operations
        )
        defer { server.stop() }

        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Timed out verifying existing socket"))
            XCTAssertTrue(error.localizedDescription.contains("refusing to replace it"))
        }
        XCTAssertEqual(observedPollTimeouts, [50])

        var preservedMetadata = stat()
        XCTAssertEqual(lstat(socketURL.path, &preservedMetadata), 0)
        XCTAssertEqual(preservedMetadata.st_dev, originalMetadata.st_dev)
        XCTAssertEqual(preservedMetadata.st_ino, originalMetadata.st_ino)
        let client = try connect(to: socketURL)
        Darwin.close(client)
    }

    func testPendingProbeRetriesInterruptedPollAndRecognizesCompletedConnection() throws {
        let directory = try makeTemporaryDirectory(prefix: "m3-probe-progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")
        let listener = try createListeningSocket(at: socketURL)
        defer { Darwin.close(listener) }

        var pollCount = 0
        var socketErrorCount = 0
        let operations = LocalHTTPServer.SocketProbeOperations(
            nowNanoseconds: { 5_000_000 },
            connect: { _, _ in .pending },
            poll: { _, _ in
                pollCount += 1
                return pollCount == 1 ? .interrupted : .ready(Int16(POLLOUT))
            },
            socketError: { _ in
                socketErrorCount += 1
                return .value(0)
            }
        )
        let server = makeServer(at: socketURL, socketProbeOperations: operations)
        defer { server.stop() }

        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("already listening"))
        }
        XCTAssertEqual(pollCount, 2)
        XCTAssertEqual(socketErrorCount, 1)

        let client = try connect(to: socketURL)
        Darwin.close(client)
    }

    func testAmbiguousProbePollFailurePreservesExistingListener() throws {
        let directory = try makeTemporaryDirectory(prefix: "m3-probe-ambiguous")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")
        let listener = try createListeningSocket(at: socketURL)
        defer { Darwin.close(listener) }

        var originalMetadata = stat()
        XCTAssertEqual(lstat(socketURL.path, &originalMetadata), 0)
        let operations = LocalHTTPServer.SocketProbeOperations(
            nowNanoseconds: { 10_000_000 },
            connect: { _, _ in .pending },
            poll: { _, _ in .ready(Int16(POLLHUP)) },
            socketError: { _ in .value(0) }
        )
        let server = makeServer(at: socketURL, socketProbeOperations: operations)
        defer { server.stop() }

        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("completed ambiguously"))
        }
        var preservedMetadata = stat()
        XCTAssertEqual(lstat(socketURL.path, &preservedMetadata), 0)
        XCTAssertEqual(preservedMetadata.st_dev, originalMetadata.st_dev)
        XCTAssertEqual(preservedMetadata.st_ino, originalMetadata.st_ino)
    }

    private func makeServer(
        at socketURL: URL,
        configuration: LocalHTTPServer.Configuration = .init(),
        socketProbeOperations: LocalHTTPServer.SocketProbeOperations = .live
    ) -> LocalHTTPServer {
        LocalHTTPServer(
            socketURL: socketURL,
            authorizer: SocketAuthorizer(token: testCapabilityToken),
            configuration: configuration,
            socketProbeOperations: socketProbeOperations,
            toolHandler: { _, _ in
                ToolResponse(ok: true, source: "test", message: "ok")
            },
            statusHandler: { _ in
                StatusResponse(
                    ok: true,
                    version: "test",
                    endpoint: socketURL.path,
                    services: [],
                    recentActivity: []
                )
            }
        )
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = URL(
            fileURLWithPath: "/private/tmp/\(prefix)-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func createStaleSocket(at socketURL: URL) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var address = makeAddress(for: socketURL.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                Darwin.bind(
                    descriptor,
                    addressPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func createListeningSocket(at socketURL: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = makeAddress(for: socketURL.path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                Darwin.bind(
                    descriptor,
                    addressPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 4) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private func connect(to socketURL: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = makeAddress(for: socketURL.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                Darwin.connect(
                    descriptor,
                    addressPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private func makeAddress(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, path, capacity)
            }
        }
        return address
    }
}

private final class LockedStartResults: @unchecked Sendable {
    private let lock = NSLock()
    private var successfulIndexes: [Int] = []
    private var failureMessages: [String] = []

    var successes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return successfulIndexes
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failureMessages
    }

    func recordSuccess(_ index: Int) {
        lock.lock()
        successfulIndexes.append(index)
        lock.unlock()
    }

    func recordFailure(_ message: String) {
        lock.lock()
        failureMessages.append(message)
        lock.unlock()
    }
}
