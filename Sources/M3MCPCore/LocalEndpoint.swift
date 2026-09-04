import Foundation

/// Location of the local MCP endpoint, shared by the app and the bridge.
///
/// The endpoint is a Unix domain socket rather than a loopback TCP port. A TCP port on 127.0.0.1 is
/// reachable by every process on the machine, including sandboxed apps that macOS specifically bars
/// from reading the data the app re-exposes. A socket file makes the boundary a filesystem one:
/// the directory is `0700` and the socket is `0600`, so only the user's own unsandboxed processes
/// can connect, and a web page cannot reach it at all.
///
/// Those permissions are the outer layer, not the whole of it. "the user's own unsandboxed
/// processes" is a large set, and every one of them used to inherit the app's Full Disk Access by
/// connecting. `SocketAuthorizer` now requires a capability token on everything but `GET /health`,
/// and `PeerIdentity` checks which binary is on the other end.
public enum M3MCPEndpoint {
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, including the terminator.
    public static let maximumSocketPathLength = 103

    /// Environment variable that relocates the socket, so a second build can run beside an installed
    /// one instead of taking its socket over.
    ///
    /// `LocalHTTPServer.start()` has to `unlink` the socket path before it binds — a file left behind
    /// by a crash would otherwise make `bind` fail with `EADDRINUSE` forever. That makes the path a
    /// single-occupancy resource: starting a development build on the default path silently
    /// disconnects the installed app's bridge. Pointing this variable at a scratch directory is what
    /// makes testing a change safe while the installed app keeps serving.
    ///
    /// Both the app and the bridge read it, so they must be given the same value.
    public static let directoryEnvironmentKey = "M3MCP_SOCKET_DIR"

    public static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment[directoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
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
