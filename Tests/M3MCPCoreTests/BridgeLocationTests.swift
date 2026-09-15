import Foundation
import XCTest
@testable import M3MCPCore

final class BridgeLocationTests: XCTestCase {
    func testSandboxBundleUsesIndependentEmbeddedHelper() {
        let app = URL(fileURLWithPath: "/Applications/Local MCP.app/Contents/MacOS/M3MCPApp")
        XCTAssertEqual(TrustedClient.bridgeURL(appExecutableURL: app, sandboxed: true).path,
            "/Applications/Local MCP.app/Contents/Helpers/LocalMCPBridge.app/Contents/MacOS/M3MCPBridge")
    }

    func testDirectDistributionAndSwiftPMRetainSiblingBridge() {
        for path in ["/Applications/LocalMCP.app/Contents/MacOS/M3MCPApp", "/tmp/build/release/M3MCPApp"] {
            let app = URL(fileURLWithPath: path)
            XCTAssertEqual(TrustedClient.bridgeURL(appExecutableURL: app, sandboxed: false),
                app.deletingLastPathComponent().appendingPathComponent("M3MCPBridge"))
        }
    }
}
