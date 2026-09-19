import Foundation
import XCTest
@testable import M3MCPApp

final class UsageRiskConsentTests: XCTestCase {
    @MainActor
    func testStartingOrRestartingWithoutConsentOnlyOpensSetup() throws {
        let suite = "M3MCP.UsageRiskTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        // Existing users must explicitly accept the new MCP sharing disclosure.
        preferences.set(1, forKey: "m3mcp.setup.usageRisk.acceptedVersion")
        preferences.set(true, forKey: "m3mcp.setup.v1.completed")
        let model = AppModel(preferences: preferences)
        model.startIfNeeded()
        XCTAssertFalse(model.usageRiskAccepted)
        XCTAssertEqual(model.serverState, "stopped")
        XCTAssertFalse(model.hasCapabilityToken)
        XCTAssertTrue(model.showsSetup)

        model.showsSetup = false // Cancelling the sheet is not consent.
        model.restart()
        XCTAssertFalse(model.usageRiskAccepted)
        XCTAssertEqual(model.serverState, "stopped")
        XCTAssertFalse(model.hasCapabilityToken)
        XCTAssertTrue(model.showsSetup)
    }

    @MainActor
    func testExplicitConsentPersistsWithoutGrantingPermissionsOrStartingServer() throws {
        let suite = "M3MCP.UsageRiskTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: preferences)
        let originalPolicy = model.enabledToolCount
        model.acceptUsageRisk()
        XCTAssertTrue(model.usageRiskAccepted)
        XCTAssertEqual(model.enabledToolCount, originalPolicy)
        XCTAssertEqual(model.serverState, "stopped")
        XCTAssertTrue(model.permissionItems.isEmpty)
        XCTAssertTrue(AppModel(preferences: preferences).usageRiskAccepted)
    }

    @MainActor
    func testUnrecognizedNoticeVersionRequiresNewConsent() throws {
        let suite = "M3MCP.UsageRiskTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(-1, forKey: "m3mcp.setup.usageRisk.acceptedVersion")
        XCTAssertFalse(AppModel(preferences: preferences).usageRiskAccepted)
    }
}
