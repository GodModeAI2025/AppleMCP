import Darwin
import Foundation
import AppKit
import M3MCPCore

enum ConnectionCheck {
    @MainActor static var diagnostic: String?

    /// One check at a time is admitted by AppModel. The bridge writes one fixed short line and
    /// exits; stderr is discarded so credentials and provider diagnostics cannot enter the UI.
    static func run(bridge: URL, environment: [String: String]) async -> Bool {
        #if LOCALMCP_SANDBOX
        return await runIndependentApp(bridge: bridge, environment: environment)
        #else
        return await Task.detached(priority: .utility) {
            runBlocking(bridge: bridge, environment: environment)
        }.value
        #endif
    }

    #if LOCALMCP_SANDBOX
    /// Launch Services gives the helper its own sandbox. Process() would inherit the parent's
    /// sandbox before the helper initializes its independent one, which libsecinit rejects.
    @MainActor
    private static func runIndependentApp(bridge: URL, environment: [String: String]) async -> Bool {
        diagnostic = nil
        let identifier = UUID().uuidString
        let directory = M3MCPEndpoint.directoryURL.appendingPathComponent("check-" + identifier)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch { diagnostic = String(localized: "Diagnoseordner: \((error as NSError).domain) / \((error as NSError).code)"); return false }
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultURL = directory.appendingPathComponent("result")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        // Sandbox callers cannot pass argv. The opening Apple event carries this one-shot
        // diagnostic request in memory, without persisting the capability token to a file.
        let event = NSAppleEventDescriptor(eventClass: 0x6C6D6370, eventID: 0x74657374,
            targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: identifier), forKeyword: 0x6C6D4944)
        event.setParam(NSAppleEventDescriptor(string: environment[CapabilityToken.environmentKey] ?? ""),
            forKeyword: 0x6C6D544B)
        configuration.appleEvent = event
        let appURL = bridge.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let application: NSRunningApplication
        do {
            application = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            diagnostic = String(localized: "Bridge-Start: \((error as NSError).domain) / \((error as NSError).code)")
            return (try? Data(contentsOf: resultURL)) == Data("M3MCP_CONNECTION_OK\n".utf8)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline && !Task.isCancelled {
            if let data = try? Data(contentsOf: resultURL) {
                diagnostic = String(localized: "Bridge hat die Anmeldung abgelehnt.")
                return data == Data("M3MCP_CONNECTION_OK\n".utf8)
            }

            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        diagnostic = String(localized: "Bridge-Diagnose hat das Zeitlimit überschritten.")
        application.terminate()
        return false
    }
    #endif

    private static func runBlocking(bridge: URL, environment: [String: String]) -> Bool {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = bridge
            process.arguments = ["--check-connection"]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return false
            }
            let data = (try? pipe.fileHandleForReading.read(upToCount: 256)) ?? Data()
            return process.terminationStatus == 0
                && String(decoding: data, as: UTF8.self) == "M3MCP_CONNECTION_OK\n"
    }
}
