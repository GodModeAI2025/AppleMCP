import Foundation
import Security
import XCTest
@testable import M3MCPCore

final class CapabilityTokenTests: XCTestCase {
    // MARK: - Primitives

    func testGeneratedTokensAreDistinctAndSurviveAConfigFile() throws {
        var seen = Set<String>()
        for _ in 0..<64 {
            let token = try CapabilityToken.generate()
            XCTAssertEqual(token.count, 43, "32 random bytes in unpadded base64url are 43 characters")
            XCTAssertTrue(
                token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" },
                "a token must survive an environment variable, a JSON string and an HTTP header: \(token)"
            )
            XCTAssertTrue(seen.insert(token).inserted, "SecRandomCopyBytes repeated a token")
        }
    }

    func testComparisonRejectsPrefixesLengthMismatchesAndEmptyExpectations() {
        XCTAssertTrue(CapabilityToken.matches("abc", "abc"))
        XCTAssertFalse(CapabilityToken.matches("ab", "abc"))
        XCTAssertFalse(CapabilityToken.matches("abcd", "abc"))
        XCTAssertFalse(CapabilityToken.matches("abd", "abc"))
        // An unconfigured server must not accept the empty string as its own token.
        XCTAssertFalse(CapabilityToken.matches("", ""))
        XCTAssertFalse(CapabilityToken.matches("anything", ""))
    }

    func testBearerParsingIgnoresSchemeCaseAndRejectsEverythingElse() {
        XCTAssertEqual(SocketAuthorizer.bearerToken(in: "Bearer abc"), "abc")
        XCTAssertEqual(SocketAuthorizer.bearerToken(in: "bearer abc"), "abc")
        XCTAssertEqual(SocketAuthorizer.bearerToken(in: "  BEARER   abc  "), "abc")
        XCTAssertNil(SocketAuthorizer.bearerToken(in: "Basic abc"))
        XCTAssertNil(SocketAuthorizer.bearerToken(in: "abc"))
        XCTAssertNil(SocketAuthorizer.bearerToken(in: "Bearer"))
        XCTAssertNil(SocketAuthorizer.bearerToken(in: "Bearer  "))
        XCTAssertNil(SocketAuthorizer.bearerToken(in: nil))
    }

    // MARK: - Decisions

    func testHealthIsTheOnlyPathThatAnswersWithoutAToken() {
        XCTAssertTrue(SocketAuthorizer.isPublic(method: "GET", path: "/health"))
        XCTAssertFalse(SocketAuthorizer.isPublic(method: "GET", path: "/status"))
        XCTAssertFalse(SocketAuthorizer.isPublic(method: "POST", path: "/health"))
        XCTAssertFalse(SocketAuthorizer.isPublic(method: "GET", path: "/health/../status"))
    }

    func testTheAuthorizerRefusesAMissingAndAWrongToken() {
        let authorizer = SocketAuthorizer(token: "expected")

        XCTAssertEqual(
            authorizer.authorize(method: "POST", path: "/tools/mail_search", authorizationHeader: nil),
            .deny(
                status: 401,
                reason: "This endpoint needs a capability token. Send 'Authorization: Bearer <token>'. "
                    + "M3MCPBridge reads the token from M3MCP_TOKEN or from the login keychain; "
                    + "the M3MCP app shows it under Server."
            )
        )
        XCTAssertEqual(
            authorizer.authorize(
                method: "POST",
                path: "/tools/mail_search",
                authorizationHeader: "Bearer wrong"
            ),
            .deny(status: 401, reason: "The capability token is not the one this M3MCP instance issued.")
        )
        XCTAssertEqual(
            authorizer.authorize(
                method: "POST",
                path: "/tools/mail_search",
                authorizationHeader: "Bearer expected"
            ),
            .allow
        )
        XCTAssertEqual(
            authorizer.authorize(method: "GET", path: "/health", authorizationHeader: nil),
            .allow
        )
    }

    // MARK: - Resolution

    func testTheEnvironmentOverrideWinsOverTheKeychain() throws {
        // Reading a variable this process does not set proves the fall-through, not the override, so
        // exercise the override through the documented variable itself.
        guard ProcessInfo.processInfo.environment[CapabilityToken.environmentKey] == nil else {
            throw XCTSkip("\(CapabilityToken.environmentKey) is already set in this environment")
        }
        setenv(CapabilityToken.environmentKey, "from-environment", 1)
        defer { unsetenv(CapabilityToken.environmentKey) }

        let resolved = try CapabilityToken.loadOrCreate(service: "de.markzimmermann.m3mcp.test.never-used")
        XCTAssertEqual(resolved.token, "from-environment")
        XCTAssertTrue(resolved.origin.contains(CapabilityToken.environmentKey))

        switch CapabilityToken.forClient(service: "de.markzimmermann.m3mcp.test.never-used") {
        case .resolved(let client):
            XCTAssertEqual(client.token, "from-environment")
        case .missing(let reason):
            XCTFail("the environment override was not seen by a client: \(reason)")
        }
    }

    /// The keychain is the part that cannot be faked, so it is exercised for real and skipped rather
    /// than failed where the login keychain is unavailable, as it can be on a CI runner.
    func testAnItemThisBinaryWroteIsReadableAgainWithoutInteraction() throws {
        let service = "de.markzimmermann.m3mcp.test.\(UUID().uuidString)"
        let token = try CapabilityToken.generate()

        do {
            try CapabilityToken.write(token: token, service: service, account: CapabilityToken.defaultAccount)
        } catch {
            throw XCTSkip("no writable login keychain in this environment: \(error.localizedDescription)")
        }
        defer { try? CapabilityToken.delete(service: service, account: CapabilityToken.defaultAccount) }

        XCTAssertEqual(
            try CapabilityToken.read(service: service, account: CapabilityToken.defaultAccount),
            token
        )

        // The bridge's path: no interaction allowed. The item was created by this same binary, so it
        // is on its own ACL and must come back without a panel.
        let started = Date()
        let withoutInteraction = try CapabilityToken.read(
            service: service,
            account: CapabilityToken.defaultAccount,
            allowingInteraction: false
        )
        XCTAssertEqual(withoutInteraction, token)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            5,
            "a non-interactive keychain read must be bounded, not a hang"
        )

        try CapabilityToken.delete(service: service, account: CapabilityToken.defaultAccount)
        XCTAssertNil(try CapabilityToken.read(service: service, account: CapabilityToken.defaultAccount))
    }

    func testAClientReportsAMissingItemRatherThanInventingAToken() throws {
        guard ProcessInfo.processInfo.environment[CapabilityToken.environmentKey] == nil else {
            throw XCTSkip("\(CapabilityToken.environmentKey) is set, so the keychain path is not reached")
        }

        let service = "de.markzimmermann.m3mcp.test.\(UUID().uuidString)"
        switch CapabilityToken.forClient(service: service) {
        case .resolved(let resolution):
            XCTFail("a client invented the token \(resolution.origin)")
        case .missing(let reason):
            XCTAssertTrue(reason.contains(service), reason)
        }
    }
}
