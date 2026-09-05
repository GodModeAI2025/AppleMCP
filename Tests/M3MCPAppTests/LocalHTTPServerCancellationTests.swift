import Darwin
import Foundation
import M3MCPCore
import XCTest
@testable import M3MCPApp

final class LocalHTTPServerCancellationTests: XCTestCase {
    func testDefaultConnectionAndFramingLimitsRemainBounded() {
        let configuration = LocalHTTPServer.Configuration()
        XCTAssertEqual(configuration.maximumConcurrentConnections, 16)
        XCTAssertEqual(configuration.requestLimits.maximumHeaderBytes, 32 * 1_024)
        XCTAssertEqual(
            configuration.requestLimits.maximumBodyBytes,
            M3MCPProtocolEngine.defaultMaximumMessageBytes
        )
        XCTAssertEqual(configuration.requestReadDeadline, 15)
        XCTAssertEqual(configuration.responseWriteDeadline, 15)
    }

    func testPeerEOFAbortsLongHandlerSuppressesResponseAndRecoversOnlySlot() async throws {
        // sockaddr_un has a small fixed path field. Use the real short temp root rather than the
        // much longer per-user temporaryDirectory symlink used by Foundation on macOS.
        let nonce = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/m3c-\(nonce)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")

        let handlerStarted = expectation(description: "long handler started")
        let handlerCancelled = expectation(description: "long handler observed cancellation")
        let statusCount = LockedCounter()

        var configuration = LocalHTTPServer.Configuration()
        configuration.maximumConcurrentConnections = 1
        configuration.readTimeout = 2
        configuration.writeTimeout = 2

        let server = LocalHTTPServer(
            socketURL: socketURL,
            authorizer: SocketAuthorizer(token: testCapabilityToken),
            configuration: configuration,
            toolHandler: { _, _ in
                handlerStarted.fulfill()
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return ToolResponse(ok: true, source: "test", message: "unexpected completion")
                } catch is CancellationError {
                    handlerCancelled.fulfill()
                    return ToolResponse(ok: false, source: "test", message: "cancelled")
                } catch {
                    return ToolResponse(ok: false, source: "test", message: error.localizedDescription)
                }
            },
            statusHandler: { _ in
                statusCount.increment()
                return StatusResponse(
                    ok: true,
                    version: "test",
                    endpoint: socketURL.path,
                    services: [],
                    recentActivity: []
                )
            }
        )
        try server.start()
        defer { server.stop() }

        let client = try connect(to: socketURL)
        defer { Darwin.close(client) }
        try writeAll(
            Data(
                "POST /tools/source_status HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Bearer \(testCapabilityToken)\r\nContent-Length: 2\r\n\r\n{}".utf8
            ),
            to: client
        )
        await fulfillment(of: [handlerStarted], timeout: 3)

        // Keep the read side open so the test can prove the server emits no response after it sees
        // EOF on the request side. The bridge uses a full shutdown for cancellation; both produce
        // the same EOF/HUP signal observed by the server monitor.
        XCTAssertEqual(Darwin.shutdown(client, SHUT_WR), 0)
        await fulfillment(of: [handlerCancelled], timeout: 3)
        let cancelledConnectionBytes = try readUntilClose(from: client, timeout: 3)
        XCTAssertTrue(cancelledConnectionBytes.isEmpty, "server wrote a response after cancellation")

        // With a one-slot test configuration, a succeeding health probe proves the cancelled task
        // released its connection slot and left the listener usable.
        let health = try await eventuallyFetchHealth(from: socketURL, timeout: 3)
        XCTAssertTrue(String(decoding: health, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertGreaterThanOrEqual(statusCount.value, 1)
    }

    func testAbsoluteRequestDeadlineRejectsATrickleClientAndRecoversSlot() async throws {
        let nonce = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/m3d-\(nonce)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")

        var configuration = LocalHTTPServer.Configuration()
        configuration.maximumConcurrentConnections = 1
        configuration.requestReadDeadline = 0.2
        // A per-read timeout much longer than the assertion window proves the absolute deadline,
        // rather than SO_RCVTIMEO, is what rejects the client.
        configuration.readTimeout = 2
        configuration.writeTimeout = 2

        let server = LocalHTTPServer(
            socketURL: socketURL,
            authorizer: SocketAuthorizer(token: testCapabilityToken),
            configuration: configuration,
            toolHandler: { _, _ in
                ToolResponse(ok: true, source: "test", message: "unexpected dispatch")
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
        try server.start()
        defer { server.stop() }

        let client = try connect(to: socketURL)
        defer { Darwin.close(client) }
        for byte in Data("GET".utf8) {
            do {
                try writeAll(Data([byte]), to: client)
            } catch {
                let code = (error as? POSIXError)?.code
                guard code == .EPIPE || code == .ECONNRESET else { throw error }
                // Under instrumentation the absolute deadline can close the server side before
                // the final trickle byte. The buffered 408 response remains the behavior asserted.
                break
            }
            try await Task.sleep(nanoseconds: 70_000_000)
        }

        let response = try readUntilClose(from: client, timeout: 1)
        XCTAssertTrue(
            String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 408 Request Timeout\r\n")
        )

        let health = try await eventuallyFetchHealth(from: socketURL, timeout: 2)
        XCTAssertTrue(String(decoding: health, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
    }

    func testAbsoluteResponseDeadlineRejectsANonReadingClientAndRecoversOnlySlot() async throws {
        let nonce = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/m3w-\(nonce)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")

        let firstStatusStarted = expectation(description: "large response handler started")
        let statusCount = LockedCounter()
        // Stay below the shared 8 MiB response cap while remaining far above a local socket's
        // send buffer, so this test isolates response-write backpressure rather than size rejection.
        let largeVersion = String(repeating: "x", count: 7 * 1_024 * 1_024)

        var configuration = LocalHTTPServer.Configuration()
        configuration.maximumConcurrentConnections = 1
        configuration.responseWriteDeadline = 0.1
        // If the implementation relied only on SO_SNDTIMEO, this client would retain the sole
        // connection slot beyond the health-probe window below.
        configuration.writeTimeout = 10

        let server = LocalHTTPServer(
            socketURL: socketURL,
            authorizer: SocketAuthorizer(token: testCapabilityToken),
            configuration: configuration,
            toolHandler: { _, _ in
                ToolResponse(ok: true, source: "test", message: "unexpected dispatch")
            },
            statusHandler: { _ in
                let invocation = statusCount.incrementAndGet()
                if invocation == 1 {
                    firstStatusStarted.fulfill()
                }
                return StatusResponse(
                    ok: true,
                    version: invocation == 1 ? largeVersion : "test",
                    endpoint: socketURL.path,
                    services: [],
                    recentActivity: []
                )
            }
        )
        try server.start()
        defer { server.stop() }

        let stalledClient = try connect(to: socketURL)
        defer { Darwin.close(stalledClient) }
        var receiveBufferBytes: Int32 = 1_024
        XCTAssertEqual(
            setsockopt(
                stalledClient,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ),
            0
        )
        try writeAll(Data("GET /health HTTP/1.1\r\n\r\n".utf8), to: stalledClient)
        await fulfillment(of: [firstStatusStarted], timeout: 2)

        // Do not read a byte from the first response. A successful second health request proves
        // that the absolute write deadline forced cleanup of the first connection and released the
        // server's only slot well before the ten-second socket timeout.
        let health = try await eventuallyFetchHealth(from: socketURL, timeout: 3)
        XCTAssertTrue(String(decoding: health, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertGreaterThanOrEqual(statusCount.value, 2)

        let abandonedResponse = try readUntilClose(from: stalledClient, timeout: 1)
        XCTAssertLessThan(
            abandonedResponse.count,
            largeVersion.utf8.count,
            "non-reading client unexpectedly received the complete oversized response"
        )
    }

    func testStopCancelsActiveHandlerAndClosesItsConnection() async throws {
        let nonce = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/m3s-\(nonce)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")
        let handlerStarted = expectation(description: "handler started")
        let handlerCancelled = expectation(description: "handler cancelled by stop")

        let server = LocalHTTPServer(
            socketURL: socketURL,
            authorizer: SocketAuthorizer(token: testCapabilityToken),
            toolHandler: { _, _ in
                handlerStarted.fulfill()
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return ToolResponse(ok: true, source: "test", message: "unexpected completion")
                } catch is CancellationError {
                    handlerCancelled.fulfill()
                    return ToolResponse(ok: false, source: "test", message: "cancelled")
                } catch {
                    return ToolResponse(ok: false, source: "test", message: error.localizedDescription)
                }
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
        try server.start()

        let client = try connect(to: socketURL)
        defer { Darwin.close(client) }
        try writeAll(
            Data(
                "POST /tools/source_status HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Bearer \(testCapabilityToken)\r\nContent-Length: 2\r\n\r\n{}".utf8
            ),
            to: client
        )
        await fulfillment(of: [handlerStarted], timeout: 2)

        server.stop()
        await fulfillment(of: [handlerCancelled], timeout: 2)
        XCTAssertTrue(try readUntilClose(from: client, timeout: 2).isEmpty)
    }

    func testLocalServiceFailsClosedWhenTaskWasAlreadyCancelled() async {
        let gate = AsyncGate()
        let service = LocalMCPService()
        let task = Task {
            await gate.wait()
            return await service.handle(tool: "source_status", input: [:])
        }

        task.cancel()
        await gate.open()
        let response = await task.value

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.source, "M3MCP Cancellation")
        XCTAssertTrue(response.message?.contains("client disconnected") == true)
    }

    func testCancellationAfterApprovalPromptPreventsShortcutDispatch() async {
        let approvalEntered = expectation(description: "approval handler entered")
        let approvalGate = AsyncGate()
        let policy = M3MCPSecurityPolicy(
            configuration: .init(allowUserShortcuts: true)
        )
        let service = LocalMCPService(
            securityPolicy: policy,
            approvalHandler: { _ in
                approvalEntered.fulfill()
                await approvalGate.wait()
                return true
            }
        )

        let task = Task {
            await service.handle(
                tool: "ai_translate",
                input: ["text": .string("hello"), "target_language": .string("de")]
            )
        }
        await fulfillment(of: [approvalEntered], timeout: 3)
        task.cancel()
        await approvalGate.open()

        let response = await task.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.source, "M3MCP Cancellation")
    }

    func testOversizedProviderResponseBecomesBoundedParseable413() async throws {
        let nonce = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/m3o-\(nonce)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("server.sock")

        let oversizedMessage = String(
            repeating: "x",
            count: LocalHTTPResponseParser.maximumBodyBytes + 1
        )
        let server = LocalHTTPServer(
            socketURL: socketURL,
            authorizer: SocketAuthorizer(token: testCapabilityToken),
            toolHandler: { _, _ in
                ToolResponse(ok: true, source: "hostile-provider", message: oversizedMessage)
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
        try server.start()
        defer { server.stop() }

        let client = try connect(to: socketURL)
        defer { Darwin.close(client) }
        try writeAll(
            Data(
                "POST /tools/source_status HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Bearer \(testCapabilityToken)\r\nContent-Length: 2\r\n\r\n{}".utf8
            ),
            to: client
        )

        let wire = try readUntilClose(from: client, timeout: 5)
        XCTAssertLessThanOrEqual(wire.count, LocalHTTPResponseParser.maximumWireBytes)
        let response = try LocalHTTPResponseParser.parse(wire)
        XCTAssertEqual(response.status, 413)
        XCTAssertLessThan(response.body.count, LocalHTTPResponseParser.maximumBodyBytes)
        let error = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.body) as? [String: String]
        )
        XCTAssertTrue(error["error"]?.contains("transport limit") == true)
        XCTAssertTrue(
            error["error"]?.contains(String(LocalHTTPResponseParser.maximumBodyBytes)) == true
        )
        XCTAssertFalse(error["error"]?.contains(oversizedMessage) == true)
    }

    private func eventuallyFetchHealth(from socketURL: URL, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var lastResponse = Data()

        repeat {
            let descriptor = try connect(to: socketURL)
            do {
                try writeAll(Data("GET /health HTTP/1.1\r\n\r\n".utf8), to: descriptor)
                lastResponse = try readUntilClose(from: descriptor, timeout: 1)
                Darwin.close(descriptor)
                if String(decoding: lastResponse, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n") {
                    return lastResponse
                }
            } catch {
                Darwin.close(descriptor)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline

        return lastResponse
    }

    private func connect(to socketURL: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        // A timing failure should surface as EPIPE in the test instead of terminating the entire
        // xctest process with SIGPIPE. Production sockets apply the same protection on accept.
        var suppressSIGPIPE: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppressSIGPIPE,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, socketURL.path, capacity)
            }
        }

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

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
    }

    private func readUntilClose(from descriptor: Int32, timeout: TimeInterval) throws -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            var readiness = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let ready = Darwin.poll(&readiness, 1, Int32(timeout * 1_000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else {
                throw POSIXError(ready == 0 ? .ETIMEDOUT : (.init(rawValue: errno) ?? .EIO))
            }

            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 { return result }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            result.append(contentsOf: bytes[0..<count])
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
