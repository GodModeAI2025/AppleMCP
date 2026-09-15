import Foundation
import M3MCPCore

@main
enum M3MCPBridgeMain {
    static func main() async {
        #if LOCALMCP_SANDBOX
        if await SandboxDiagnosticApplication.runIfLaunchedWithoutInput() { return }
        #endif
        if CommandLine.arguments.dropFirst().elementsEqual(["--check-connection"]) {
            // Exercises the same token and signed-peer checks as a real MCP tool call. No user
            // content, server output, paths or credentials are printed by this diagnostic mode.
            let response = await LocalAppClient(timeout: 8).call(tool: "source_status", arguments: [:])
            print(response.ok ? "M3MCP_CONNECTION_OK" : "M3MCP_CONNECTION_FAILED")
            return
        }
        await MCPServer().run()
    }
}
