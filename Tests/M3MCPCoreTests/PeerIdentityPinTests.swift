import Foundation
import XCTest
@testable import M3MCPCore

final class PeerIdentityPinTests: XCTestCase {
    private let bundledBridge = "1111111111111111111111111111111111111111"

    private func pinnedAuthorizer() -> SocketAuthorizer {
        SocketAuthorizer(
            token: "expected",
            trustedCodeDirectoryHashes: [bundledBridge],
            trustDescription: "pinned to /Applications/M3MCP.app/Contents/MacOS/M3MCPBridge"
        )
    }

    private func peer(hash: String?, valid: Bool = true) -> PeerIdentity {
        PeerIdentity(
            processIdentifier: 4_242,
            userIdentifier: 501,
            signingIdentifier: "SomeClient",
            codeDirectoryHash: hash,
            executablePath: "/tmp/someclient",
            signatureValid: valid
        )
    }

    func testAValidTokenFromThePinnedBinaryGoesThrough() {
        XCTAssertEqual(
            pinnedAuthorizer().authorize(
                method: "POST",
                path: "/tools/mail_search",
                authorizationHeader: "Bearer expected",
                peer: peer(hash: bundledBridge)
            ),
            .allow
        )
    }

    /// The pin is stored and compared lowercased, because `codesign` prints one case and callers of
    /// `M3MCP_TRUSTED_CLIENT_CDHASH` will eventually paste the other.
    func testHashComparisonIgnoresCase() {
        let authorizer = SocketAuthorizer(
            token: "expected",
            trustedCodeDirectoryHashes: ["ABCDEF0123456789"]
        )
        XCTAssertEqual(
            authorizer.authorize(
                method: "POST",
                path: "/tools/mail_search",
                authorizationHeader: "Bearer expected",
                peer: peer(hash: "abcdef0123456789")
            ),
            .allow
        )
    }

    func testAValidTokenFromAnotherBinaryIsForbiddenRatherThanUnauthorized() {
        let decision = pinnedAuthorizer().authorize(
            method: "POST",
            path: "/tools/mail_search",
            authorizationHeader: "Bearer expected",
            peer: peer(hash: "2222222222222222222222222222222222222222")
        )
        guard case .deny(let status, let reason) = decision else {
            return XCTFail("a copied token from another binary was allowed")
        }
        // 401 and 403 are different answers on purpose: the first says "configure a token", the
        // second says "that token is not yours to use from there".
        XCTAssertEqual(status, 403)
        XCTAssertTrue(reason.contains("M3MCPBridge that ships with this app"), reason)
        XCTAssertTrue(reason.contains("/Applications/M3MCP.app"), reason)
    }

    func testAPeerWithoutAVerifiableSignatureIsRefusedWhilePinningIsOn() {
        let unsigned = pinnedAuthorizer().authorize(
            method: "POST",
            path: "/tools/mail_search",
            authorizationHeader: "Bearer expected",
            peer: peer(hash: nil)
        )
        XCTAssertEqual(unsigned, pinnedDenial(unsigned))

        let tampered = pinnedAuthorizer().authorize(
            method: "POST",
            path: "/tools/mail_search",
            authorizationHeader: "Bearer expected",
            peer: peer(hash: bundledBridge, valid: false)
        )
        // The right hash with a failed validity check is still a refusal: validity is what catches a
        // binary whose pages were changed after signing.
        XCTAssertEqual(tampered, pinnedDenial(tampered))
    }

    private func pinnedDenial(_ decision: SocketAuthorizer.Decision) -> SocketAuthorizer.Decision {
        guard case .deny(let status, let reason) = decision else {
            XCTFail("expected a refusal")
            return decision
        }
        XCTAssertEqual(status, 403)
        XCTAssertTrue(reason.contains("no verifiable code signature"), reason)
        return decision
    }

    /// A missing pin must be a stated fallback, not a silent one.
    func testWithoutAPinTheTokenAloneDecidesAndTheStateSaysSo() {
        let authorizer = SocketAuthorizer(token: "expected")
        XCTAssertFalse(authorizer.pinsPeerIdentity)
        XCTAssertTrue(authorizer.pinningDescription.contains("not pinned"), authorizer.pinningDescription)
        XCTAssertEqual(
            authorizer.authorize(
                method: "POST",
                path: "/tools/mail_search",
                authorizationHeader: "Bearer expected",
                peer: peer(hash: nil, valid: false)
            ),
            .allow
        )
        XCTAssertTrue(pinnedAuthorizer().pinsPeerIdentity)
        XCTAssertTrue(
            pinnedAuthorizer().pinningDescription.contains("pinned client"),
            pinnedAuthorizer().pinningDescription
        )
    }

    // MARK: - Against the real Security framework

    func testThisProcessHasACodeDirectoryHashAndAFileOnDiskReportsTheSameOne() throws {
        guard let running = PeerIdentity.codeDirectoryHashOfCurrentProcess() else {
            throw XCTSkip("this test runner has no readable code signature")
        }
        XCTAssertEqual(running.count, 40, "a SHA-1-truncated code directory hash is 40 hex characters")

        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        guard let onDisk = PeerIdentity.codeDirectoryHash(ofFileAt: executable) else {
            throw XCTSkip("the test runner executable at \(executable.path) has no readable signature")
        }
        XCTAssertEqual(running, onDisk, "the pin computed from a file must match the running process")
    }

    func testAPathThatIsNotAMachOBinaryYieldsNoHashRatherThanAWrongOne() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/m3pin-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notABinary = directory.appendingPathComponent("M3MCPBridge")
        try Data("not a binary".utf8).write(to: notABinary)

        XCTAssertNil(PeerIdentity.codeDirectoryHash(ofFileAt: notABinary))
    }

    // MARK: - Resolving what to pin

    func testTheSiblingBridgeIsWhatGetsPinned() throws {
        // A signed Mach-O binary that is cheap to copy. The code directory hash is embedded in the
        // file, so a copy of it reports the same hash, which is what makes the expectation exact.
        let source = URL(fileURLWithPath: "/bin/echo")
        guard let expected = PeerIdentity.codeDirectoryHash(ofFileAt: source) else {
            throw XCTSkip("\(source.path) has no readable code signature on this machine")
        }

        let directory = URL(fileURLWithPath: "/private/tmp/m3trust-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Stand in for an installed bundle: an app executable with a bridge next to it.
        let app = directory.appendingPathComponent("M3MCPApp")
        let bridge = directory.appendingPathComponent(TrustedClient.bridgeExecutableName)
        try FileManager.default.copyItem(at: source, to: app)
        try FileManager.default.copyItem(at: source, to: bridge)

        let resolution = TrustedClient.resolve(appExecutableURL: app)
        XCTAssertEqual(resolution.hashes, [expected])
        XCTAssertTrue(resolution.note.contains(bridge.path), resolution.note)

        // The pin follows the sibling: replace the bridge and the next resolution names the new one.
        try FileManager.default.removeItem(at: bridge)
        let replaced = TrustedClient.resolve(appExecutableURL: app)
        XCTAssertTrue(replaced.hashes.isEmpty)
        XCTAssertTrue(replaced.note.contains("no M3MCPBridge next to"), replaced.note)
    }

    func testAMissingSiblingBridgeIsReportedRatherThanQuietlyDroppingThePin() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/m3trust-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("M3MCPApp")
        try Data("app".utf8).write(to: app)

        let resolution = TrustedClient.resolve(appExecutableURL: app)
        XCTAssertTrue(resolution.hashes.isEmpty)
        XCTAssertTrue(resolution.note.contains("no M3MCPBridge next to"), resolution.note)

        let unknownExecutable = TrustedClient.resolve(appExecutableURL: nil)
        XCTAssertTrue(unknownExecutable.hashes.isEmpty)
        XCTAssertTrue(unknownExecutable.note.contains("not pinned"), unknownExecutable.note)
    }

    func testTheEnvironmentOverrideReplacesTheSiblingLookup() throws {
        guard ProcessInfo.processInfo.environment[TrustedClient.environmentKey] == nil else {
            throw XCTSkip("\(TrustedClient.environmentKey) is already set in this environment")
        }
        setenv(TrustedClient.environmentKey, " AAAA , bbbb ,, ", 1)
        defer { unsetenv(TrustedClient.environmentKey) }

        let resolution = TrustedClient.resolve(appExecutableURL: nil)
        XCTAssertEqual(resolution.hashes, ["aaaa", "bbbb"])
        XCTAssertTrue(resolution.note.contains(TrustedClient.environmentKey), resolution.note)
    }
}
