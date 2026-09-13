#if LOCALMCP_SANDBOX
import AppKit
import Darwin
import Foundation
import M3MCPCore
import OSLog

/// A Launch Services invocation has /dev/null as stdin. MCP clients use a pipe/socket and retain
/// the normal STDIO server. Only a token-authenticated, fixed source_status call is accepted here.
@MainActor
final class SandboxDiagnosticApplication: NSObject {
    static weak var current: SandboxDiagnosticApplication?
    private var started = false

    static func runIfLaunchedWithoutInput() -> Bool {
        let log = Logger(subsystem: "de.mobilebox.LocalMCP.Bridge", category: "connection-check")
        log.notice("Diagnostic launch entry; argument count: \(CommandLine.arguments.count, privacy: .public)")
        guard CommandLine.arguments.count == 1 else { return false }
        let nullDescriptor = open("/dev/null", O_RDONLY)
        guard nullDescriptor >= 0 else { return false }
        defer { close(nullDescriptor) }
        var input = stat()
        var null = stat()
        guard fstat(STDIN_FILENO, &input) == 0, fstat(nullDescriptor, &null) == 0,
              input.st_mode & S_IFMT == S_IFCHR, input.st_rdev == null.st_rdev else { log.notice("STDIO mode selected"); return false }
        log.notice("App event mode selected")
        let handler = SandboxDiagnosticApplication()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        current = handler
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { app.terminate(nil) }
        withExtendedLifetime(handler) { app.run() }
        return true
    }

    func check(nonce: String?, token: String?) {
        Logger(subsystem: "de.mobilebox.LocalMCP.Bridge", category: "connection-check").notice("Diagnostic command received")
        guard !started,
              let nonce,
              let identifier = UUID(uuidString: nonce), identifier.uuidString == nonce,
              let token,
              !token.isEmpty, token.utf8.count <= 1024,
              M3MCPEndpoint.configurationError == nil else { return }
        started = true
        let directory = M3MCPEndpoint.directoryURL.appendingPathComponent("check-" + nonce)
        Task.detached {
            let response = await LocalAppClient(timeout: 8, capabilityToken: token)
                .call(tool: "source_status", arguments: [:])
            let marker = response.ok ? "M3MCP_CONNECTION_OK\n" : "M3MCP_CONNECTION_FAILED\n"
            // Never create the parent: a timed-out/cancelled check cannot publish a late result.
            try? Data(marker.utf8).write(to: directory.appendingPathComponent("result"), options: .atomic)
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }
}

/// Cocoa scripting dispatches the declared command after its own launch initialization.
@objc(LocalMCPDiagnosticCommand)
final class LocalMCPDiagnosticCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let nonce = evaluatedArguments?["identifier"] as? String
        let token = evaluatedArguments?["capability"] as? String
        Task { @MainActor in
            SandboxDiagnosticApplication.current?.check(nonce: nonce, token: token)
        }
        return nil
    }
}
#endif
