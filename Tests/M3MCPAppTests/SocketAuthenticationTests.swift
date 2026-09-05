import Darwin
import Foundation
import M3MCPCore
import XCTest
@testable import M3MCPApp

/// Drives a real listener over a real Unix socket, because the thing under test is the door and a
/// door has to be tried from outside.
final class SocketAuthenticationTests: XCTestCase {
    private var directory: URL!
    private var socketURL: URL!
    private var server: LocalHTTPServer!
    private var accessLog: AccessLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeShortTemporaryDirectory(prefix: "m3auth")
        socketURL = directory.appendingPathComponent("server.sock")
        accessLog = AccessLog()

        let log = accessLog!
        let endpoint = socketURL!
        server = LocalHTTPServer(
            socketURL: endpoint,
            authorizer: SocketAuthorizer(token: testCapabilityToken),
            toolHandler: { tool, _ in
                ToolResponse(ok: true, source: "test", message: "handled \(tool)")
            },
            statusHandler: { includeActivity in
                StatusResponse(
                    ok: true,
                    version: "test",
                    endpoint: endpoint.path,
                    services: [],
                    recentActivity: includeActivity
                        ? [
                            ActivityEntry(
                                endpoint: "m3mcp://tools/mail_search",
                                provider: "Mail",
                                status: "ok",
                                detail: "1 item(s)",
                                durationMilliseconds: 1,
                                toolName: "mail_search",
                                inputJSON: "{\"query\":\"secret\"}",
                                outputJSON: "{\"ok\":true}"
                            )
                        ]
                        : []
                )
            },
            auditHandler: { attempt in
                log.append(attempt)
            }
        )
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Token

    func testToolCallWithoutTokenIsRefused() throws {
        let reply = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "source_status", token: nil)
        )
        XCTAssertEqual(reply.statusLine, "HTTP/1.1 401 Unauthorized")
        XCTAssertTrue(reply.body.contains("needs a capability token"), reply.body)
        XCTAssertEqual(accessLog.refusals.map(\.path), ["/tools/source_status"])
        XCTAssertEqual(accessLog.refusals.map(\.allowed), [false])
    }

    func testToolCallWithTheWrongTokenIsRefused() throws {
        let reply = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "source_status", token: testCapabilityToken + "x")
        )
        XCTAssertEqual(reply.statusLine, "HTTP/1.1 401 Unauthorized")
        XCTAssertTrue(reply.body.contains("not the one this M3MCP instance issued"), reply.body)
    }

    func testToolCallWithTheConfiguredTokenGoesThrough() throws {
        let reply = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "source_status", token: testCapabilityToken)
        )
        XCTAssertEqual(reply.statusLine, "HTTP/1.1 200 OK")
        XCTAssertTrue(reply.body.contains("handled source_status"), reply.body)
        XCTAssertTrue(accessLog.refusals.isEmpty, "an accepted call was logged as a refusal")
    }

    /// The bridge decodes a tool reply as a `ToolResponse`. A refusal shaped as anything else
    /// reaches the MCP client as "unreadable response" rather than as the reason.
    func testARefusedToolCallDecodesAsAToolResponseInTheBridge() throws {
        let reply = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "mail_search", token: nil)
        )
        let decoded = try M3JSON.makeDecoder().decode(ToolResponse.self, from: Data(reply.body.utf8))
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.source, "M3MCP Server")
        XCTAssertTrue(decoded.message?.contains("capability token") == true, decoded.message ?? "")
    }

    // MARK: - Health and status

    func testHealthAnswersWithoutATokenAndCarriesNoActivityLog() throws {
        let reply = try exchangeOverSocket(
            at: socketURL,
            request: "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(reply.statusLine, "HTTP/1.1 200 OK")

        let status = try M3JSON.makeDecoder().decode(StatusResponse.self, from: Data(reply.body.utf8))
        XCTAssertTrue(status.recentActivity.isEmpty, "the public probe leaked the activity log")
        XCTAssertTrue(accessLog.refusals.isEmpty)
    }

    func testStatusNeedsTheTokenBecauseItCarriesTheActivityLog() throws {
        let refused = try exchangeOverSocket(
            at: socketURL,
            request: "GET /status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(refused.statusLine, "HTTP/1.1 401 Unauthorized")
        XCTAssertFalse(refused.body.contains("secret"), "a refused /status still returned activity")

        let allowed = try exchangeOverSocket(
            at: socketURL,
            request: "GET /status HTTP/1.1\r\nHost: localhost\r\n"
                + "Authorization: Bearer \(testCapabilityToken)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(allowed.statusLine, "HTTP/1.1 200 OK")
        let status = try M3JSON.makeDecoder().decode(StatusResponse.self, from: Data(allowed.body.utf8))
        XCTAssertEqual(status.recentActivity.count, 1)
    }

    // MARK: - Header handling

    func testTheSchemeIsCaseInsensitiveAndOtherSchemesAreRefused() throws {
        let lowercase = try exchangeOverSocket(
            at: socketURL,
            request: "GET /status HTTP/1.1\r\nHost: localhost\r\n"
                + "authorization: bearer \(testCapabilityToken)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(lowercase.statusLine, "HTTP/1.1 200 OK")

        let basic = try exchangeOverSocket(
            at: socketURL,
            request: "GET /status HTTP/1.1\r\nHost: localhost\r\n"
                + "Authorization: Basic \(testCapabilityToken)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(basic.statusLine, "HTTP/1.1 401 Unauthorized")
    }
}

private final class AccessLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AccessAttempt] = []

    var refusals: [AccessAttempt] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { !$0.allowed }
    }

    func append(_ attempt: AccessAttempt) {
        lock.lock()
        storage.append(attempt)
        lock.unlock()
    }
}
