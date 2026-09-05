import Darwin
import Foundation
import M3MCPCore
import XCTest
@testable import M3MCPApp

/// Availability is part of the access control here, because authorization cannot happen before the
/// request has been read whole: the token is a header. So a connection that says nothing must not be
/// able to take the endpoint away from the client that holds the token.
final class SocketAvailabilityTests: XCTestCase {
    private var directory: URL!
    private var socketURL: URL!
    private var server: LocalHTTPServer!
    private var idle: [Int32] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeShortTemporaryDirectory(prefix: "m3load")
        socketURL = directory.appendingPathComponent("server.sock")
    }

    override func tearDownWithError() throws {
        for descriptor in idle {
            Darwin.close(descriptor)
        }
        idle = []
        server?.stop()
        server = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func startServer(
        openConnections: Int = 4,
        concurrentRequests: Int = 4,
        requestReadDeadline: TimeInterval = 15,
        toolHandler: @escaping LocalHTTPServer.ToolHandler = { tool, _ in
            ToolResponse(ok: true, source: "test", message: "handled \(tool)")
        }
    ) throws {
        var configuration = LocalHTTPServer.Configuration()
        configuration.maximumOpenConnections = openConnections
        configuration.maximumConcurrentConnections = concurrentRequests
        configuration.requestReadDeadline = requestReadDeadline

        let endpoint = socketURL!
        let server = LocalHTTPServer(
            socketURL: endpoint,
            authorizer: SocketAuthorizer(token: testCapabilityToken),
            configuration: configuration,
            toolHandler: toolHandler,
            statusHandler: { _ in
                StatusResponse(
                    ok: true,
                    version: "test",
                    endpoint: endpoint.path,
                    services: [],
                    recentActivity: []
                )
            }
        )
        try server.start()
        self.server = server
    }

    /// Opens connections that say nothing at all, the cheapest local attack there is.
    @discardableResult
    private func openSilentConnections(_ count: Int) -> Int {
        for _ in 0..<count {
            if let descriptor = connectToSocketWithRetry(at: socketURL) {
                idle.append(descriptor)
            }
        }
        // The accept loop admits from its own queue; give it a moment to take them all in.
        Thread.sleep(forTimeInterval: 0.15)
        return idle.count
    }

    // MARK: - Silence must not buy an outage

    func testSilentConnectionsAtTheCapDoNotTakeTheEndpointAway() throws {
        try startServer(openConnections: 4)
        XCTAssertEqual(openSilentConnections(4), 4)

        let health = try exchangeOverSocket(
            at: socketURL,
            request: "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(health.statusLine, "HTTP/1.1 200 OK")

        let call = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "source_status", token: testCapabilityToken)
        )
        XCTAssertEqual(call.statusLine, "HTTP/1.1 200 OK")
        XCTAssertTrue(call.body.contains("handled source_status"), call.body)
    }

    /// Far past the cap, and repeatedly: the point is that filling every slot buys a burst and not
    /// an outage, because each new arrival costs the flooder its oldest slot.
    func testManyMoreSilentConnectionsThanSlotsStillYieldTheEndpoint() throws {
        try startServer(openConnections: 16)
        XCTAssertGreaterThanOrEqual(openSilentConnections(160), 16)

        for attempt in 1...5 {
            let call = try exchangeOverSocket(
                at: socketURL,
                request: toolCallRequest(tool: "source_status", token: testCapabilityToken)
            )
            XCTAssertEqual(call.statusLine, "HTTP/1.1 200 OK", "attempt \(attempt)")
        }
    }

    /// The displaced connection is told why, rather than being closed without a word.
    func testTheDisplacedConnectionIsToldWhy() throws {
        try startServer(openConnections: 1)
        let victim = try connectToSocket(at: socketURL)
        defer { Darwin.close(victim) }
        Thread.sleep(forTimeInterval: 0.15)

        let call = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "source_status", token: testCapabilityToken)
        )
        XCTAssertEqual(call.statusLine, "HTTP/1.1 200 OK")

        let displaced = try readUntilSocketClose(from: victim, timeout: 2)
        let text = String(decoding: displaced, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"), text)
        XCTAssertTrue(text.contains("Displaced by a newer connection"), text)
    }

    // MARK: - A half-read request is work in progress

    /// A connection that has sent something is not silent, so it is not displaced. When every slot
    /// holds one of those, the refusal is the honest answer.
    func testAConnectionThatHasSentSomethingIsNotDisplacedAndTheCapThenHolds() throws {
        try startServer(openConnections: 2)

        var partial: [Int32] = []
        for _ in 0..<2 {
            let descriptor = try connectToSocket(at: socketURL)
            partial.append(descriptor)
            idle.append(descriptor)
            try writeAllToSocket(Data("GET /heal".utf8), to: descriptor)
        }
        Thread.sleep(forTimeInterval: 0.2)

        let refused = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "source_status", token: testCapabilityToken),
            timeout: 3
        )
        XCTAssertEqual(refused.statusLine, "HTTP/1.1 503 Service Unavailable")
        XCTAssertTrue(refused.body.contains("connection limit"), refused.body)

        // The half-read requests survived and still complete.
        for descriptor in partial {
            try writeAllToSocket(Data("th HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8), to: descriptor)
        }
        for descriptor in partial {
            let reply = try readUntilSocketClose(from: descriptor, timeout: 3)
            XCTAssertTrue(
                String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"),
                "a half-read request was thrown away instead of finished"
            )
        }
    }

    // MARK: - Deadlines

    func testAnUnfinishedRequestIsDroppedWhenTheDeadlinePassesAndTheSlotComesBack() throws {
        try startServer(openConnections: 1, requestReadDeadline: 0.3)

        let stalled = try connectToSocket(at: socketURL)
        defer { Darwin.close(stalled) }
        try writeAllToSocket(Data("GET /heal".utf8), to: stalled)

        let reply = try readUntilSocketClose(from: stalled, timeout: 3)
        let text = String(decoding: reply, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 408 Request Timeout\r\n"), text)

        // The one slot is back, so the endpoint works again without anything else being closed.
        let health = try exchangeOverSocket(
            at: socketURL,
            request: "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(health.statusLine, "HTTP/1.1 200 OK")
    }

    /// A client that shuts down its write side after half a request still gets told why, the way it
    /// did when the request was read by a parked thread.
    func testAHalfOpenClientIsToldItsRequestWasIncomplete() throws {
        try startServer(openConnections: 2)

        let client = try connectToSocket(at: socketURL)
        defer { Darwin.close(client) }
        try writeAllToSocket(Data("GET /heal".utf8), to: client)
        XCTAssertEqual(Darwin.shutdown(client, SHUT_WR), 0)

        let reply = try readUntilSocketClose(from: client, timeout: 3)
        let text = String(decoding: reply, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), text)
        XCTAssertTrue(text.contains("Could not read a complete request"), text)
    }

    // MARK: - The in-flight cap is a separate, honest limit

    /// Silence is cheap and a thread is the price of having said something. When every serving slot
    /// is busy the answer is 503, and it arrives at once rather than after a wait.
    func testARequestBeyondTheInFlightCapIsRefusedPromptly() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        try startServer(openConnections: 8, concurrentRequests: 1, toolHandler: { tool, _ in
            started.signal()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    release.wait()
                    continuation.resume()
                }
            }
            return ToolResponse(ok: true, source: "test", message: "handled \(tool)")
        })

        let slow = try connectToSocket(at: socketURL)
        defer { Darwin.close(slow) }
        try writeAllToSocket(
            Data(toolCallRequest(tool: "source_status", token: testCapabilityToken).utf8),
            to: slow
        )
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)

        let began = Date()
        let refused = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "source_status", token: testCapabilityToken),
            timeout: 3
        )
        XCTAssertEqual(refused.statusLine, "HTTP/1.1 503 Service Unavailable")
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "the refusal waited for the busy slot")

        release.signal()
        let finished = try readUntilSocketClose(from: slow, timeout: 5)
        XCTAssertTrue(String(decoding: finished, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
    }
}
