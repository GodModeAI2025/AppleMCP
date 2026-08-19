import Foundation

/// Location of the local MCP endpoint, shared by the app and the bridge.
///
/// The endpoint is a Unix domain socket rather than a loopback TCP port. A TCP port on 127.0.0.1 is
/// reachable by every process on the machine, including sandboxed apps that macOS specifically bars
/// from reading the data the app re-exposes. A socket file makes the boundary a filesystem one:
/// the directory is `0700` and the socket is `0600`, so only the user's own unsandboxed processes
/// can connect, and a web page cannot reach it at all.
public enum M3MCPEndpoint {
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, including the terminator.
    public static let maximumSocketPathLength = 103

    public static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/M3MCP", isDirectory: true)
    }

    public static var socketURL: URL {
        directoryURL.appendingPathComponent("mcp.sock", isDirectory: false)
    }

    /// Shown in the UI and in diagnostics.
    public static var displayPath: String {
        socketURL.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    /// Ready-to-paste probe, since `curl` speaks Unix sockets.
    public static var healthCommand: String {
        "curl --unix-socket '\(socketURL.path)' http://localhost/health"
    }
}
