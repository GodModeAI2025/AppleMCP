import Darwin
import Foundation
import XCTest
@testable import M3MCPCore

/// The confirmation is checked at the socket, not in the tool schema.
///
/// `MCPServer` answers `tools/list` out of `ToolCatalog` without ever contacting the app, so
/// `tools/list | grep confirm_token` says only that the bridge advertises a parameter. What matters
/// is that a `POST /tools/calendar_delete_event` without one changes nothing, and these tests make
/// that call over a real Unix socket.
final class WriteConfirmationTests: XCTestCase {
    private var directory: URL!
    private var server: LocalHTTPServer?

    private let token = "test-token-cccccccccccccccccccccccccccc"

    /// Set by the stub tool handler when a call gets past the guard.
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func append(_ entry: String) {
            lock.lock(); defer { lock.unlock() }
            entries.append(entry)
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    private let executed = Ledger()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("m3w\(UInt32.random(in: 0..<0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private var socketURL: URL { directory.appendingPathComponent("mcp.sock", isDirectory: false) }

    /// The same `WriteGuard` the app puts in front of its providers, with a stub in place of EventKit
    /// so a test never touches a real calendar.
    private func startServer(guard writeGuard: WriteGuard = WriteGuard()) throws {
        let executed = self.executed
        let server = LocalHTTPServer(
            socketURL: socketURL,
            authorizer: SocketAuthorizer(token: token),
            toolHandler: { tool, input in
                switch writeGuard.evaluate(tool: tool, input: input) {
                case .challenge(let challenge):
                    return challenge.response()
                case .execute(let confirmed):
                    executed.append(tool)
                    return ToolResponse(
                        ok: true,
                        source: "EventKit",
                        message: "wrote \(tool) with \(confirmed.count) argument(s)",
                        meta: ["confirm_token_present": String(confirmed[WriteConfirmation.argumentName] != nil)]
                    )
                }
            },
            statusHandler: {
                StatusResponse(ok: true, version: m3mcpVersion, endpoint: "test", services: [], recentActivity: [])
            }
        )
        try server.start()
        self.server = server
    }

    // MARK: - Over the socket

    func testDeleteWithoutAConfirmTokenChangesNothingAndHandsOutOne() throws {
        try startServer()
        let reply = try post("/tools/calendar_delete_event", #"{"id":"ABC-123"}"#)

        XCTAssertEqual(reply.status, 400)
        let response = try M3JSON.makeDecoder().decode(ToolResponse.self, from: reply.body)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.meta?["confirm_required"], "true")
        XCTAssertEqual(response.meta?["confirm_argument"], "confirm_token")
        XCTAssertFalse(response.meta?["confirm_token"]?.isEmpty ?? true)
        XCTAssertTrue(response.message?.contains("Nothing has been written") == true, response.message ?? "")
        XCTAssertEqual(executed.all, [], "the write ran despite the missing confirmation")
    }

    func testTheHandedOutTokenConfirmsTheSameCall() throws {
        try startServer()

        let challenge = try M3JSON.makeDecoder().decode(
            ToolResponse.self,
            from: try post("/tools/calendar_delete_event", #"{"id":"ABC-123"}"#).body
        )
        let confirmToken = try XCTUnwrap(challenge.meta?["confirm_token"])

        let reply = try post("/tools/calendar_delete_event", #"{"id":"ABC-123","confirm_token":"\#(confirmToken)"}"#)
        XCTAssertEqual(reply.status, 200)
        let response = try M3JSON.makeDecoder().decode(ToolResponse.self, from: reply.body)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(executed.all, ["calendar_delete_event"])
        // The provider never sees the token.
        XCTAssertEqual(response.meta?["confirm_token_present"], "false")
    }

    func testATokenIssuedForOneEventDoesNotConfirmAnother() throws {
        try startServer()

        let challenge = try M3JSON.makeDecoder().decode(
            ToolResponse.self,
            from: try post("/tools/calendar_delete_event", #"{"id":"ABC-123"}"#).body
        )
        let confirmToken = try XCTUnwrap(challenge.meta?["confirm_token"])

        let reply = try post("/tools/calendar_delete_event", #"{"id":"OTHER-999","confirm_token":"\#(confirmToken)"}"#)
        XCTAssertEqual(reply.status, 400)
        let response = try M3JSON.makeDecoder().decode(ToolResponse.self, from: reply.body)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("issued for different arguments") == true, response.message ?? "")
        XCTAssertEqual(executed.all, [])
    }

    func testAnInventedTokenDoesNotConfirmAnything() throws {
        try startServer()
        let far = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let reply = try post(
            "/tools/calendar_delete_calendar",
            #"{"id":"X","title":"Y","confirm_token":"\#(far).notarealsignature"}"#
        )

        XCTAssertEqual(reply.status, 400)
        let response = try M3JSON.makeDecoder().decode(ToolResponse.self, from: reply.body)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(executed.all, [])
    }

    func testEveryCalendarWriteToolIsGuardedAndReadsAreNot() throws {
        try startServer()

        for tool in WriteGuard.calendarWriteTools.sorted() {
            let reply = try post("/tools/\(tool)", #"{"id":"ABC-123","title":"T"}"#)
            let response = try M3JSON.makeDecoder().decode(ToolResponse.self, from: reply.body)
            XCTAssertFalse(response.ok, tool)
            XCTAssertEqual(response.meta?["confirm_required"], "true", tool)
        }
        XCTAssertEqual(executed.all, [])

        for tool in ["calendar_search", "calendar_read_event", "calendar_list_calendars", "mail_search"] {
            let reply = try post("/tools/\(tool)", #"{"query":"x"}"#)
            XCTAssertEqual(reply.status, 200, tool)
        }
        XCTAssertEqual(executed.all.count, 4)
    }

    // MARK: - The token itself

    func testTokenExpires() throws {
        let confirmation = WriteConfirmation(validity: 300)
        let now = Date()
        let issued = confirmation.issue(tool: "calendar_delete_event", input: ["id": .string("A")], now: now)

        XCTAssertEqual(
            confirmation.verify(token: issued.token, tool: "calendar_delete_event", input: ["id": .string("A")], now: now.addingTimeInterval(299)),
            .valid
        )
        XCTAssertEqual(
            confirmation.verify(token: issued.token, tool: "calendar_delete_event", input: ["id": .string("A")], now: now.addingTimeInterval(301)),
            .expired
        )
    }

    func testTokenIsBoundToTheToolAsWellAsTheArguments() {
        let confirmation = WriteConfirmation()
        let input: [String: JSONValue] = ["id": .string("A")]
        let issued = confirmation.issue(tool: "calendar_delete_event", input: input)

        XCTAssertEqual(confirmation.verify(token: issued.token, tool: "calendar_delete_event", input: input), .valid)
        XCTAssertEqual(confirmation.verify(token: issued.token, tool: "calendar_delete_calendar", input: input), .mismatched)
    }

    func testTokenSurvivesReorderedArgumentsButNotChangedOnes() {
        let confirmation = WriteConfirmation()
        let issued = confirmation.issue(
            tool: "calendar_update_event",
            input: ["id": .string("A"), "title": .string("Retro"), "all_day": .bool(false)]
        )

        // JSON objects are unordered; the same call written differently must still confirm.
        XCTAssertEqual(
            confirmation.verify(
                token: issued.token,
                tool: "calendar_update_event",
                input: ["all_day": .bool(false), "title": .string("Retro"), "id": .string("A")]
            ),
            .valid
        )
        XCTAssertEqual(
            confirmation.verify(
                token: issued.token,
                tool: "calendar_update_event",
                input: ["id": .string("A"), "title": .string("Retro"), "all_day": .bool(true)]
            ),
            .mismatched
        )
    }

    func testKeysAreNotSharedBetweenInstances() {
        let issued = WriteConfirmation().issue(tool: "calendar_delete_event", input: ["id": .string("A")])
        // A restart makes a new key, so a token from the previous run is void rather than still good.
        XCTAssertEqual(
            WriteConfirmation().verify(token: issued.token, tool: "calendar_delete_event", input: ["id": .string("A")]),
            .mismatched
        )
    }

    func testMalformedAndMissingTokensAreToldApart() {
        let confirmation = WriteConfirmation()
        let input: [String: JSONValue] = ["id": .string("A")]
        XCTAssertEqual(confirmation.verify(token: nil, tool: "calendar_delete_event", input: input), .missing)
        XCTAssertEqual(confirmation.verify(token: "", tool: "calendar_delete_event", input: input), .missing)
        XCTAssertEqual(confirmation.verify(token: "not-a-token", tool: "calendar_delete_event", input: input), .malformed)
    }

    func testCanonicalTextIsStableAndDistinguishesShapes() {
        XCTAssertEqual(JSONValue.object(["b": .number(1), "a": .number(2)]).canonicalText, #"{"a":2,"b":1}"#)
        XCTAssertEqual(JSONValue.number(3.0).canonicalText, "3")
        XCTAssertEqual(JSONValue.string("a\"b\nc").canonicalText, #""a\"b\nc""#)
        XCTAssertNotEqual(JSONValue.string("1").canonicalText, JSONValue.number(1).canonicalText)
        XCTAssertNotEqual(
            JSONValue.object(["a": .string("b")]).canonicalText,
            JSONValue.object(["ab": .null]).canonicalText
        )
    }

    // MARK: - HTTP over the socket

    private struct Reply {
        let status: Int
        let body: Data
    }

    private func post(_ path: String, _ json: String) throws -> Reply {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure("socket() failed") }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, socketURL.path, capacity)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure("connect() failed: \(String(cString: strerror(errno)))") }

        let body = Data(json.utf8)
        var request = Data()
        request.append(Data("POST \(path) HTTP/1.1\r\n".utf8))
        request.append(Data("Host: localhost\r\n".utf8))
        request.append(Data("Content-Type: application/json\r\n".utf8))
        request.append(Data("Authorization: Bearer \(token)\r\n".utf8))
        request.append(Data("Content-Length: \(body.count)\r\n".utf8))
        request.append(Data("Connection: close\r\n\r\n".utf8))
        request.append(body)

        try request.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw Failure("write() failed") }
                offset += written
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw in read(descriptor, raw.baseAddress, raw.count) }
            if count == 0 { break }
            guard count > 0 else { throw Failure("read() failed") }
            buffer.append(contentsOf: chunk[0..<count])
        }

        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8),
              let statusLine = headerText.components(separatedBy: "\r\n").first,
              let code = Int(statusLine.split(separator: " ")[1])
        else {
            throw Failure("the server sent no readable status line")
        }

        return Reply(status: code, body: Data(buffer[headerEnd.upperBound...]))
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
