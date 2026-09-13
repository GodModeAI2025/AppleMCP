import Foundation
import M3MCPCore

/// A separately built fixture, never embedded in the distributed app.
@main
struct TransportProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let bridge = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let hash = PeerIdentity.codeDirectoryHash(ofFileAt: bridge) else { exit(3) }
        let endpoint = M3MCPEndpoint.socketURL
        let server = LocalHTTPServer(socketURL: endpoint,
            authorizer: SocketAuthorizer(token: "synthetic-sandbox-transport-token",
                trustedCodeDirectoryHashes: [hash], trustDescription: "runtime fixture"),
            toolHandler: { name, _ in ToolResponse(ok: true, source: "synthetic", message: "handled \(name)") },
            statusHandler: { _ in StatusResponse(ok: true, version: "fixture", endpoint: endpoint.path,
                services: [], recentActivity: []) })
        try server.start()
        defer { server.stop() }
        print("READY \(endpoint.path)")
        fflush(stdout)
        _ = await Task.detached { FileHandle.standardInput.readDataToEndOfFile() }.value
    }
}
