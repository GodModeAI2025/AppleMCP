import Darwin
import Foundation
import XCTest
@testable import M3MCPCore

/// Exercises the access control on the real socket rather than on the tool schema.
///
/// The bridge answers `tools/list` out of its own catalog without ever asking the app, so grepping a
/// schema proves nothing about what the server does. Every test here opens the Unix socket, writes
/// an HTTP request by hand and reads the status line back.
final class SocketAuthenticationTests: XCTestCase {
    private var directory: URL!
    private var server: LocalHTTPServer?

    private let token = "test-token-aaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short path on purpose: sockaddr_un.sun_path holds 103 usable bytes.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("m3\(UInt32.random(in: 0..<0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private var socketURL: URL { directory.appendingPathComponent("mcp.sock", isDirectory: false) }

    @discardableResult
    private func startServer(
        pinnedTo hashes: Set<String> = [],
        requestTimeout: TimeInterval = 10,
        maximumOpenConnections: Int = 128
    ) throws -> LocalHTTPServer {
        let server = LocalHTTPServer(
            socketURL: socketURL,
            authorizer: SocketAuthorizer(token: token, trustedCodeDirectoryHashes: hashes),
            toolHandler: { tool, input in
                ToolResponse(
                    ok: true,
                    source: "test",
                    items: [DataItem(id: tool, title: tool, kind: "test", source: "test")],
                    message: "ran \(tool) with \(input.count) argument(s)"
                )
            },
            statusHandler: {
                StatusResponse(
                    ok: true,
                    version: m3mcpVersion,
                    endpoint: "test",
                    services: [ServiceHealth(name: "Test", endpoint: "t://", mode: "test", state: "on-demand")],
                    recentActivity: [
                        ActivityEntry(
                            endpoint: "mail://local-index",
                            provider: "Mail",
                            status: "ok",
                            detail: "1 item(s)",
                            durationMilliseconds: 3,
                            toolName: "mail_search",
                            inputJSON: "{\"query\":\"salary negotiation\"}",
                            outputJSON: "{\"ok\":true}"
                        )
                    ]
                )
            },
            requestTimeout: requestTimeout,
            maximumOpenConnections: maximumOpenConnections
        )
        try server.start()
        self.server = server
        return server
    }

    /// Connects `count` times and sends `payload` on each, leaving every connection open.
    ///
    /// With no payload these are the silent connections the availability tests are about. The
    /// listen backlog is smaller than a burst, so a refused connect is retried: that is what an
    /// attacker with a loop of their own would do, and not retrying would measure the kernel rather
    /// than the server.
    @discardableResult
    private func openConnections(_ count: Int, sending payload: Data? = nil) -> [Int32] {
        var opened: [Int32] = []
        for _ in 0..<count {
            for attempt in 0..<40 {
                let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
                guard descriptor >= 0 else { break }
                var address = Self.address(for: socketURL.path)
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                        connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if connected == 0 {
                    if let payload {
                        _ = payload.withUnsafeBytes { raw in
                            raw.baseAddress.map { write(descriptor, $0, raw.count) }
                        }
                    }
                    opened.append(descriptor)
                    break
                }
                close(descriptor)
                usleep(useconds_t(2_000 * (attempt + 1)))
            }
        }
        return opened
    }

    /// Raises the descriptor limit where the hard limit allows it, because both ends of every
    /// connection live in this process. Returns what is available afterwards.
    private func availableDescriptors() -> rlim_t {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return 0 }
        if limits.rlim_cur < 512 {
            var raised = limits
            raised.rlim_cur = min(rlim_t(1024), limits.rlim_max)
            _ = setrlimit(RLIMIT_NOFILE, &raised)
            _ = getrlimit(RLIMIT_NOFILE, &limits)
        }
        return limits.rlim_cur
    }

    // MARK: - Token

    func testToolCallWithoutTokenIsRefused() throws {
        try startServer()
        let reply = try request(method: "POST", path: "/tools/source_status", body: Data("{}".utf8), token: nil)

        XCTAssertEqual(reply.status, 401)
        XCTAssertTrue(reply.statusLine.contains("Unauthorized"), reply.statusLine)

        // It has to arrive as a ToolResponse: that is the only shape LocalAppClient can read, so
        // anything else reaches the MCP client as "unreadable response" instead of as the reason.
        let decoded = try M3JSON.makeDecoder().decode(ToolResponse.self, from: reply.body)
        XCTAssertFalse(decoded.ok)
        XCTAssertTrue(decoded.message?.contains("capability token") == true, decoded.message ?? "")
    }

    func testToolCallWithTheWrongTokenIsRefused() throws {
        try startServer()
        let reply = try request(
            method: "POST",
            path: "/tools/source_status",
            body: Data("{}".utf8),
            token: "test-token-bbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )

        XCTAssertEqual(reply.status, 401)
        let decoded = try M3JSON.makeDecoder().decode(ToolResponse.self, from: reply.body)
        XCTAssertFalse(decoded.ok)
    }

    func testToolCallWithTheConfiguredTokenGoesThrough() throws {
        try startServer()
        let reply = try request(method: "POST", path: "/tools/source_status", body: Data("{}".utf8), token: token)

        XCTAssertEqual(reply.status, 200)
        let decoded = try M3JSON.makeDecoder().decode(ToolResponse.self, from: reply.body)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.items.first?.id, "source_status")
    }

    // MARK: - Peer identity

    func testTokenFromAnUnpinnedBinaryIsRefused() throws {
        // A hash no process on this machine can have: the token is right, the binary is not.
        try startServer(pinnedTo: ["0000000000000000000000000000000000000000"])
        let reply = try request(method: "POST", path: "/tools/source_status", body: Data("{}".utf8), token: token)

        XCTAssertEqual(reply.status, 403)
        XCTAssertTrue(reply.statusLine.contains("Forbidden"), reply.statusLine)
        let decoded = try M3JSON.makeDecoder().decode(ToolResponse.self, from: reply.body)
        XCTAssertFalse(decoded.ok)
        XCTAssertTrue(decoded.message?.contains("not configured for") == true, decoded.message ?? "")
    }

    func testTokenFromThePinnedBinaryGoesThrough() throws {
        let own = try XCTUnwrap(
            PeerIdentity.codeDirectoryHashOfCurrentProcess(),
            "the test binary has no code signature, so peer pinning cannot be exercised"
        )
        try startServer(pinnedTo: [own])
        let reply = try request(method: "POST", path: "/tools/source_status", body: Data("{}".utf8), token: token)

        XCTAssertEqual(reply.status, 200)
    }

    func testPeerOfAConnectionResolvesToThisProcess() throws {
        try startServer()

        // Same check the server makes, run against a connection this test opens itself.
        let listener = try makeListener(at: directory.appendingPathComponent("peer.sock", isDirectory: false))
        defer { close(listener.descriptor); unlink(listener.path) }

        DispatchQueue.global().async {
            let client = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = Self.address(for: listener.path)
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    connect(client, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
            close(client)
        }

        let accepted = accept(listener.descriptor, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }

        let peer = PeerIdentity.resolve(descriptor: accepted)
        XCTAssertEqual(peer.processIdentifier, getpid())
        XCTAssertEqual(peer.userIdentifier, getuid())
        XCTAssertTrue(peer.signatureValid, peer.note ?? "no note")
        XCTAssertEqual(peer.codeDirectoryHash, PeerIdentity.codeDirectoryHashOfCurrentProcess())
    }

    // MARK: - Health and status

    func testHealthAnswersWithoutATokenAndCarriesNoActivityLog() throws {
        try startServer()
        let reply = try request(method: "GET", path: "/health", body: nil, token: nil)

        XCTAssertEqual(reply.status, 200)
        let status = try M3JSON.makeDecoder().decode(StatusResponse.self, from: reply.body)
        XCTAssertEqual(status.version, m3mcpVersion)
        // The activity log holds the arguments and results of past tool calls. It must not be on the
        // one path that answers without a token.
        XCTAssertTrue(status.recentActivity.isEmpty)
        XCTAssertFalse(String(data: reply.body, encoding: .utf8)?.contains("salary negotiation") ?? true)
        XCTAssertTrue(status.services.contains { $0.name == "Client Authentication" })
    }

    func testStatusNeedsTheTokenBecauseItCarriesTheActivityLog() throws {
        try startServer()

        let refused = try request(method: "GET", path: "/status", body: nil, token: nil)
        XCTAssertEqual(refused.status, 401)
        XCTAssertFalse(String(data: refused.body, encoding: .utf8)?.contains("salary negotiation") ?? true)

        let allowed = try request(method: "GET", path: "/status", body: nil, token: token)
        XCTAssertEqual(allowed.status, 200)
        let status = try M3JSON.makeDecoder().decode(StatusResponse.self, from: allowed.body)
        XCTAssertEqual(status.recentActivity.count, 1)
    }

    // MARK: - Token primitives

    func testBearerParsingIgnoresCaseAndRejectsOtherSchemes() {
        XCTAssertEqual(SocketAuthorizer.bearerToken(in: "Bearer abc"), "abc")
        XCTAssertEqual(SocketAuthorizer.bearerToken(in: "bearer abc"), "abc")
        XCTAssertEqual(SocketAuthorizer.bearerToken(in: "  BEARER   abc  "), "abc")
        XCTAssertNil(SocketAuthorizer.bearerToken(in: "Basic abc"))
        XCTAssertNil(SocketAuthorizer.bearerToken(in: "Bearer"))
        XCTAssertNil(SocketAuthorizer.bearerToken(in: "Bearer "))
        XCTAssertNil(SocketAuthorizer.bearerToken(in: nil))
    }

    func testTokenComparisonRejectsPrefixesAndEmptyExpectations() {
        XCTAssertTrue(CapabilityToken.matches("abcdef", "abcdef"))
        XCTAssertFalse(CapabilityToken.matches("abcde", "abcdef"))
        XCTAssertFalse(CapabilityToken.matches("abcdefg", "abcdef"))
        XCTAssertFalse(CapabilityToken.matches("", ""))
        XCTAssertFalse(CapabilityToken.matches("abcdef", ""))
    }

    func testGeneratedTokensAreDistinctAndConfigFileSafe() throws {
        let first = try CapabilityToken.generate()
        let second = try CapabilityToken.generate()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 43)
        XCTAssertNil(first.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").inverted))
    }

    /// The keychain path of a client, which is the default for anyone without `M3MCP_TOKEN`.
    ///
    /// The item is written here, so its ACL belongs to this test binary and not to the bridge — the
    /// same relationship the bridge has with the item the app writes. Measured before this test
    /// existed: `SecItemCopyMatching` had not returned after 25 seconds and the bridge had printed
    /// nothing, which an MCP client cannot tell from a server that is broken. What is asserted is
    /// therefore the answer, not its content: the bridge has to come back, and quickly.
    func testTheBridgeAnswersWhenItMayNotReadTheKeychainItem() throws {
        let bridge = try XCTUnwrap(Self.bridgeExecutable(), "M3MCPBridge is not built; run swift build first")
        let service = "de.markzimmermann.m3mcp.test.\(UUID().uuidString)"

        do {
            try CapabilityToken.write(token: try CapabilityToken.generate(), service: service, account: "default")
        } catch {
            throw XCTSkip("Keychain is not writable here: \(error.localizedDescription)")
        }
        defer { try? CapabilityToken.delete(service: service, account: "default") }

        let started = Date()
        let output = try run(
            bridge,
            input: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"source_status","arguments":{}}}"#,
            environment: [
                M3MCPEndpoint.directoryEnvironmentKey: directory.path,
                CapabilityToken.serviceEnvironmentKey: service
            ],
            timeout: 20
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(output.isEmpty, "the bridge answered nothing in \(elapsed)s")
        XCTAssertLessThan(elapsed, 15, "the bridge took \(elapsed)s to answer")
        if output.contains("No capability token") {
            // Whatever the keychain said, the way out has to be in the message.
            XCTAssertTrue(output.contains(CapabilityToken.environmentKey), output)
        }
    }

    /// The other half: refusing interaction must not break the case that needs none.
    func testAnItemThisBinaryWroteIsReadableWithoutInteraction() throws {
        let service = "de.markzimmermann.m3mcp.test.\(UUID().uuidString)"
        let token = try CapabilityToken.generate()

        do {
            try CapabilityToken.write(token: token, service: service, account: "default")
        } catch {
            throw XCTSkip("Keychain is not writable here: \(error.localizedDescription)")
        }
        defer { try? CapabilityToken.delete(service: service, account: "default") }

        let started = Date()
        let read = try CapabilityToken.read(service: service, account: "default", allowingInteraction: false)
        XCTAssertEqual(read, token)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testKeychainRoundTrip() throws {
        let service = "de.markzimmermann.m3mcp.test.\(UUID().uuidString)"
        let account = "test"
        let token = try CapabilityToken.generate()

        do {
            try CapabilityToken.write(token: token, service: service, account: account)
        } catch {
            // A locked or unavailable login keychain is an environment problem, not a defect.
            throw XCTSkip("Keychain is not writable here: \(error.localizedDescription)")
        }
        defer { try? CapabilityToken.delete(service: service, account: account) }

        XCTAssertEqual(try CapabilityToken.read(service: service, account: account), token)
        try CapabilityToken.delete(service: service, account: account)
        XCTAssertNil(try CapabilityToken.read(service: service, account: account))
    }

    // MARK: - The bridge as the real client

    /// The end-to-end shape: the shipped bridge binary, launched the way an MCP client launches it,
    /// against a server that enforces the token.
    func testBridgeReachesTheServerWithTheTokenAndIsRefusedWithout() throws {
        let bridge = try XCTUnwrap(Self.bridgeExecutable(), "M3MCPBridge is not built; run swift build first")
        try startServer()

        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"source_status","arguments":{}}}"#

        let configured = try run(
            bridge,
            input: call,
            environment: [
                M3MCPEndpoint.directoryEnvironmentKey: directory.path,
                CapabilityToken.environmentKey: token
            ]
        )
        XCTAssertTrue(configured.contains("\"isError\" : false") || configured.contains("\"isError\":false"), configured)
        XCTAssertTrue(configured.contains("ran source_status"), configured)

        let unconfigured = try run(
            bridge,
            input: call,
            environment: [
                M3MCPEndpoint.directoryEnvironmentKey: directory.path,
                // A keychain service that cannot exist, so this does not depend on what happens to be
                // in the developer's login keychain.
                CapabilityToken.serviceEnvironmentKey: "de.markzimmermann.m3mcp.test.\(UUID().uuidString)"
            ]
        )
        XCTAssertTrue(unconfigured.contains("No capability token"), unconfigured)
    }

    /// What the pin buys and what it does not, measured instead of claimed.
    ///
    /// Pinned to the code directory hash of the built bridge: a socket client written by hand is
    /// refused with `403` even holding the right token, and the very same token, handed by the very
    /// same process to the bridge the pin trusts, goes through and returns a tool result. The pin
    /// forces an attacker through the shipped bridge. It does not stop them using it, so any text
    /// promising that a copied token is refused would be false.
    func testThePinRefusesAHandwrittenClientAndPassesTheBundledBridge() throws {
        let bridge = try XCTUnwrap(Self.bridgeExecutable(), "M3MCPBridge is not built; run swift build first")
        let bridgeHash = try XCTUnwrap(
            PeerIdentity.codeDirectoryHash(ofFileAt: bridge),
            "the built bridge carries no readable code signature, so the pin cannot be exercised"
        )
        try startServer(pinnedTo: [bridgeHash])

        // This process is not the pinned binary. The right token is not enough.
        let handwritten = try request(
            method: "POST", path: "/tools/source_status", body: Data("{}".utf8), token: token
        )
        XCTAssertEqual(handwritten.status, 403, handwritten.statusLine)

        // The same token, from the same process, presented through the binary the pin trusts.
        let throughBridge = try run(
            bridge,
            input: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"source_status","arguments":{}}}"#,
            environment: [
                M3MCPEndpoint.directoryEnvironmentKey: directory.path,
                CapabilityToken.environmentKey: token
            ]
        )
        XCTAssertTrue(throughBridge.contains("ran source_status"), throughBridge)
    }

    /// The probe README and index.html print, and the same probe aimed at a tool.
    ///
    /// curl is the shape an attacker would reach for first, and it is also the shape the docs tell a
    /// user to run, so both outcomes belong in a test: `/health` still answers, a tool call does not.
    func testDocumentedCurlProbeAnswersAndCurlCannotCallAToolWithoutTheToken() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else {
            throw XCTSkip("no curl on this machine")
        }
        try startServer()

        let health = try curl(["--unix-socket", socketURL.path, "-s", "-o", "/dev/null",
                               "-w", "%{http_code}", "http://localhost/health"])
        XCTAssertEqual(health, "200")

        let tool = try curl(["--unix-socket", socketURL.path, "-s", "-o", "/dev/null",
                             "-w", "%{http_code}", "-X", "POST",
                             "-H", "Content-Type: application/json", "-d", "{}",
                             "http://localhost/tools/mail_search"])
        XCTAssertEqual(tool, "401")

        let authorised = try curl(["--unix-socket", socketURL.path, "-s", "-o", "/dev/null",
                                   "-w", "%{http_code}", "-X", "POST",
                                   "-H", "Content-Type: application/json",
                                   "-H", "Authorization: Bearer \(token)", "-d", "{}",
                                   "http://localhost/tools/mail_search"])
        XCTAssertEqual(authorised, "200")
    }

    private func curl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Availability

    /// A process with no token must not be able to take the endpoint away from one that has it.
    ///
    /// 120 connections that connect and then send nothing. Authorization happens after the request
    /// has been read whole, so these are never refused by the token check — they simply occupy the
    /// server. `/health` and an authorised tool call have to keep answering while they sit there.
    func testIdleConnectionsCannotStarveTheEndpoint() throws {
        // Two descriptors per connection, both ends being in this process, so the test needs headroom
        // a stock runner does not always have. Skip rather than measure something else where the
        // hard limit does not allow raising it.
        let descriptors = availableDescriptors()
        try XCTSkipUnless(
            descriptors >= 512,
            "only \(descriptors) descriptors available; 120 connections need both ends of each"
        )

        try startServer()

        let idle = openConnections(120)
        defer { for descriptor in idle { close(descriptor) } }
        XCTAssertGreaterThan(idle.count, 100, "only \(idle.count) connections were accepted")

        let started = Date()
        let health = try request(method: "GET", path: "/health", body: nil, token: nil, timeout: 8)
        XCTAssertEqual(health.status, 200, health.statusLine)

        let tool = try request(
            method: "POST", path: "/tools/source_status", body: Data("{}".utf8), token: token, timeout: 8
        )
        XCTAssertEqual(tool.status, 200, tool.statusLine)

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 8, "the endpoint took \(elapsed)s to answer behind \(idle.count) idle connections")
    }

    /// The cap itself must not become the outage.
    ///
    /// The test above stays under `maximumOpenConnections`, which is where a cap looks like a fix.
    /// This one goes past it three times over: every slot is held by a process that sent nothing,
    /// which is the cheapest attack there is. A silent slot has to yield to a real client, or the
    /// endpoint is gone for as long as the attacker keeps reconnecting.
    func testSilentConnectionsPastTheCapStillYieldTheEndpointToARealClient() throws {
        // A small cap on purpose: the point is what happens *past* it, and 8 slots make that
        // measurable without needing several hundred descriptors.
        let cap = 8
        try XCTSkipUnless(availableDescriptors() >= 256, "not enough descriptors for both ends of 24 connections")
        try startServer(maximumOpenConnections: cap)

        let silent = openConnections(cap * 3)
        defer { for descriptor in silent { close(descriptor) } }
        XCTAssertGreaterThanOrEqual(silent.count, cap * 2, "only \(silent.count) connections were accepted")

        let started = Date()
        let health = try request(method: "GET", path: "/health", body: nil, token: nil, timeout: 8)
        XCTAssertEqual(health.status, 200, "with \(silent.count) silent connections against a cap of \(cap): \(health.statusLine)")

        let tool = try request(
            method: "POST", path: "/tools/source_status", body: Data("{}".utf8), token: token, timeout: 8
        )
        XCTAssertEqual(tool.status, 200, tool.statusLine)

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 8, "the endpoint took \(elapsed)s behind \(silent.count) silent connections")
    }

    /// A half-read request is work in progress, not a free slot.
    ///
    /// Displacing it would trade one denial for another: an attacker that sends one byte per
    /// connection would then be pushing real requests out instead of being bounded by them. So when
    /// every slot holds something that has spoken, the endpoint says `503` and means it.
    func testAConnectionThatHasSentSomethingIsNotDisplacedAndTheCapThenHolds() throws {
        let cap = 4
        try startServer(maximumOpenConnections: cap)

        // A request line and no terminator: enough to fill the buffer, never enough to answer.
        let talking = openConnections(cap, sending: Data("GET /health HTTP/1.1\r\n".utf8))
        defer { for descriptor in talking { close(descriptor) } }
        XCTAssertEqual(talking.count, cap)

        // Give the server a moment to read what was sent, so the buffers are no longer empty.
        usleep(200_000)

        let reply = try request(method: "GET", path: "/health", body: nil, token: nil, timeout: 8)
        XCTAssertEqual(reply.status, 503, "a full set of partly-read requests must not be displaced: \(reply.statusLine)")
    }

    /// A request that never ends is answered and dropped, instead of being waited on.
    ///
    /// A header without its blank line is the cheapest way to hold a connection open. The deadline
    /// is what turns that from an open-ended cost into a bounded one.
    func testAnUnfinishedRequestIsDroppedWhenTheDeadlinePasses() throws {
        try startServer(requestTimeout: 1)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        var address = Self.address(for: socketURL.path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)

        var deadline = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

        // A request line and no terminator: complete enough to look like a client, never complete.
        let partial = Data("GET /health HTTP/1.1\r\nHost: localhost\r\n".utf8)
        _ = partial.withUnsafeBytes { raw in
            raw.baseAddress.map { write(descriptor, $0, raw.count) }
        }

        let started = Date()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { raw in read(descriptor, raw.baseAddress, raw.count) }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(count, 0, "the server never answered: \(String(cString: strerror(errno)))")
        let reply = String(decoding: buffer[0..<max(0, count)], as: UTF8.self)
        XCTAssertTrue(reply.contains("408"), reply)
        XCTAssertLessThan(elapsed, 5, "the deadline was 1 second, the answer took \(elapsed)s")
    }

    // MARK: - Raw HTTP over the socket

    private struct Reply {
        let statusLine: String
        let status: Int
        let body: Data
    }

    private func request(
        method: String,
        path: String,
        body: Data?,
        token: String?,
        timeout: TimeInterval = 20
    ) throws -> Reply {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure("socket() failed") }
        defer { close(descriptor) }

        // Without this a server that accepts and then never answers turns a failing test into a
        // hanging one, and a hang says nothing about what went wrong.
        var deadline = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

        // A full listen backlog is answered by the kernel with ECONNREFUSED before the server sees
        // anything, so a burst of connections from elsewhere in the test would otherwise show up here
        // as a server failure. Retrying briefly separates the two; the timing assertions are what
        // measure whether the server is actually reachable.
        var address = Self.address(for: socketURL.path)
        var connected: Int32 = -1
        for attempt in 0..<40 {
            connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 || errno != ECONNREFUSED { break }
            usleep(useconds_t(2_000 * (attempt + 1)))
        }
        guard connected == 0 else { throw Failure("connect() failed: \(String(cString: strerror(errno)))") }

        var request = Data()
        request.append(Data("\(method) \(path) HTTP/1.1\r\n".utf8))
        request.append(Data("Host: localhost\r\n".utf8))
        request.append(Data("Content-Type: application/json\r\n".utf8))
        if let token {
            request.append(Data("Authorization: Bearer \(token)\r\n".utf8))
        }
        request.append(Data("Content-Length: \(body?.count ?? 0)\r\n".utf8))
        request.append(Data("Connection: close\r\n\r\n".utf8))
        if let body { request.append(body) }

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
            guard count > 0 else {
                throw Failure("read() failed: \(String(cString: strerror(errno)))")
            }
            buffer.append(contentsOf: chunk[0..<count])
        }

        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8),
              let statusLine = headerText.components(separatedBy: "\r\n").first,
              let code = Int(statusLine.split(separator: " ")[1])
        else {
            throw Failure("the server sent no readable status line")
        }

        return Reply(statusLine: statusLine, status: code, body: Data(buffer[headerEnd.upperBound...]))
    }

    // MARK: - Helpers

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func address(for path: String) -> sockaddr_un {
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

    private func makeListener(at url: URL) throws -> (descriptor: Int32, path: String) {
        let path = url.path
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = Self.address(for: path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                Darwin.bind(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw Failure("could not listen on \(path)")
        }
        return (descriptor, path)
    }

    /// Walks up from the test bundle until it finds the built bridge next to it.
    private static func bridgeExecutable() -> URL? {
        var directory = Bundle(for: SocketAuthenticationTests.self).bundleURL
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("M3MCPBridge", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// Bounded on purpose: a child that never answers has to fail the test, not hang it. That is the
    /// whole subject of `testTheBridgeAnswersWhenItMayNotReadTheKeychainItem`.
    private func run(
        _ executable: URL,
        input: String,
        environment: [String: String],
        timeout: TimeInterval = 60
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        var environmentForRun = ProcessInfo.processInfo.environment
        // Anything inherited would decide the outcome instead of the test.
        environmentForRun.removeValue(forKey: CapabilityToken.environmentKey)
        environmentForRun.removeValue(forKey: CapabilityToken.serviceEnvironmentKey)
        for (key, value) in environment { environmentForRun[key] = value }
        process.environment = environmentForRun

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        try process.run()
        stdin.fileHandleForWriting.write(Data((input + "\n").utf8))
        try? stdin.fileHandleForWriting.close()

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: output, encoding: .utf8) ?? ""
    }
}
