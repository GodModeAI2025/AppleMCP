import Foundation
import XCTest
@testable import M3MCPCore

final class ClientConfigurationTests: XCTestCase {
    private let safe = M3MCPSecurityPolicy(configuration: .defaultSafe)

    func testJSONRoundTripsPathsAndTokensWithoutEnablingOptionalTools() throws {
        let path = "/Users/März/quoted \"name\"/LocalMCP.app/Contents/MacOS/M3MCPBridge"
        let token = "example-only-credential"
        let text = try ClientConfiguration.render(format: .json, bridgePath: path, token: token, policy: safe)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["m3mcp"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, path)
        XCTAssertEqual(server["env"] as? [String: String], ["M3MCP_TOKEN": token])
    }

    func testCodexEscapesControlCharactersAndCannotInjectAnotherTable() throws {
        let text = try ClientConfiguration.render(format: .codex,
            bridgePath: "/tmp/\"\n[mcp_servers.injected]\n\\bridge", token: "fake\nvalue", policy: safe)
        XCTAssertTrue(text.contains("\\\"\\n[mcp_servers.injected]\\n\\\\bridge"))
        XCTAssertFalse(text.contains("\n[mcp_servers.injected]"))
        XCTAssertTrue(text.contains("M3MCP_TOKEN = \"fake\\nvalue\""))
    }

    func testPreviewUsesOnlyCallerSuppliedPlaceholder() throws {
        for format in ClientConfiguration.Format.allCases {
            let text = try ClientConfiguration.render(format: format, bridgePath: "/Applications/LocalMCP.app/Contents/MacOS/M3MCPBridge", token: "<MCP_TOKEN>", policy: safe)
            XCTAssertTrue(text.contains("<MCP_TOKEN>"))
        }
    }

    func testOptInsMirrorPolicyWithoutAccidentallyEnablingOtherGroups() {
        let policy = M3MCPSecurityPolicy(configuration: .init(allowCalendarMutations: true))
        let env = ClientConfiguration.environment(token: "test", policy: policy)
        XCTAssertEqual(env["M3MCP_ENABLE_CALENDAR_MUTATIONS"], "1")
        XCTAssertNil(env["M3MCP_ENABLE_PERMISSION_UI"])
        XCTAssertNil(env["M3MCP_ENABLE_USER_SHORTCUTS"])
        XCTAssertEqual(env.count, 2)
    }
}
