import Darwin
import Foundation
import M3MCPCore
import XCTest
@testable import M3MCPApp

/// The pin, tried from outside with two different binaries: this test runner, and `/usr/bin/curl`.
/// A copied token has to stop working when it is presented by the wrong one.
final class SocketPeerPinTests: XCTestCase {
    private var directory: URL!
    private var socketURL: URL!
    private var server: LocalHTTPServer!
    private var peers: PeerLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeShortTemporaryDirectory(prefix: "m3pin")
        socketURL = directory.appendingPathComponent("server.sock")
        peers = PeerLog()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func startServer(pinnedTo hashes: Set<String>) throws {
        let log = peers!
        let endpoint = socketURL!
        let server = LocalHTTPServer(
            socketURL: endpoint,
            authorizer: SocketAuthorizer(
                token: testCapabilityToken,
                trustedCodeDirectoryHashes: hashes,
                trustDescription: "pinned to the test fixture"
            ),
            toolHandler: { tool, _ in
                ToolResponse(ok: true, source: "test", message: "handled \(tool)")
            },
            statusHandler: { _ in
                StatusResponse(
                    ok: true,
                    version: "test",
                    endpoint: endpoint.path,
                    services: [],
                    recentActivity: []
                )
            },
            auditHandler: { attempt in
                log.append(attempt)
            }
        )
        try server.start()
        self.server = server
    }

    private func ownCodeDirectoryHash() throws -> String {
        guard let hash = PeerIdentity.codeDirectoryHashOfCurrentProcess() else {
            throw XCTSkip("this test runner has no readable code signature, so nothing can be pinned to it")
        }
        return hash
    }

    // MARK: - The pinned binary

    func testThePinnedBinaryWithTheTokenGoesThrough() throws {
        try startServer(pinnedTo: [try ownCodeDirectoryHash()])

        let reply = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "source_status", token: testCapabilityToken)
        )
        XCTAssertEqual(reply.statusLine, "HTTP/1.1 200 OK")
        XCTAssertTrue(reply.body.contains("handled source_status"), reply.body)
    }

    /// The token is right and the binary is not. This is the case a token on its own cannot cover.
    func testTheSameTokenFromAnUnpinnedBinaryIsRefused() throws {
        try startServer(pinnedTo: ["0000000000000000000000000000000000000000"])

        let reply = try exchangeOverSocket(
            at: socketURL,
            request: toolCallRequest(tool: "source_status", token: testCapabilityToken)
        )
        XCTAssertEqual(reply.statusLine, "HTTP/1.1 403 Forbidden")
        XCTAssertTrue(reply.body.contains("not configured for"), reply.body)

        let refusals = peers.refusals
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals.first?.peer.processIdentifier, getpid())
        XCTAssertEqual(refusals.first?.peer.userIdentifier, getuid())
        XCTAssertEqual(refusals.first?.peer.codeDirectoryHash, try ownCodeDirectoryHash())
        XCTAssertTrue(refusals.first?.peer.signatureValid == true)
    }

    // MARK: - A genuinely foreign binary

    /// `/usr/bin/curl` is a different executable with a different code directory hash, and it is the
    /// probe the README documents. Pinned to this test runner, it must be refused even with the
    /// correct token, and must still be able to read `/health`.
    func testAForeignBinaryIsRefusedWithTheTokenAndStillReadsHealth() throws {
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        guard FileManager.default.isExecutableFile(atPath: curl.path) else {
            throw XCTSkip("no /usr/bin/curl on this machine")
        }
        try startServer(pinnedTo: [try ownCodeDirectoryHash()])

        let toolCall = try runCurl(
            arguments: [
                "--silent", "--show-error",
                "--unix-socket", socketURL.path,
                "--output", "/dev/null",
                "--write-out", "%{http_code}",
                "--header", "Content-Type: application/json",
                "--header", "Authorization: Bearer \(testCapabilityToken)",
                "--data", "{}",
                "http://localhost/tools/source_status"
            ]
        )
        XCTAssertEqual(toolCall, "403", "a foreign binary got in on a copied token")

        let health = try runCurl(
            arguments: [
                "--silent", "--show-error",
                "--unix-socket", socketURL.path,
                "--output", "/dev/null",
                "--write-out", "%{http_code}",
                "http://localhost/health"
            ]
        )
        XCTAssertEqual(health, "200", "the documented probe stopped working for other binaries")

        let refusals = peers.refusals
        XCTAssertEqual(refusals.count, 1)
        XCTAssertNotEqual(refusals.first?.peer.processIdentifier, getpid())
        XCTAssertEqual(refusals.first?.peer.executablePath, curl.path)
        XCTAssertNotEqual(refusals.first?.peer.codeDirectoryHash, try ownCodeDirectoryHash())
    }

    /// Without a pin the same foreign binary is accepted on the token alone. This is the fallback an
    /// installation without a sibling bridge falls into, and it has to be visible rather than assumed.
    func testWithoutAPinTheForeignBinaryIsAcceptedOnTheTokenAlone() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else {
            throw XCTSkip("no /usr/bin/curl on this machine")
        }
        try startServer(pinnedTo: [])

        let toolCall = try runCurl(
            arguments: [
                "--silent", "--show-error",
                "--unix-socket", socketURL.path,
                "--output", "/dev/null",
                "--write-out", "%{http_code}",
                "--header", "Content-Type: application/json",
                "--header", "Authorization: Bearer \(testCapabilityToken)",
                "--data", "{}",
                "http://localhost/tools/source_status"
            ]
        )
        XCTAssertEqual(toolCall, "200")
        XCTAssertTrue(peers.refusals.isEmpty)
    }

    private func runCurl(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class PeerLog: @unchecked Sendable {
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
