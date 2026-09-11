import Darwin
import Foundation

enum ConnectionCheck {
    /// One check at a time is admitted by AppModel. The bridge writes one fixed short line and
    /// exits; stderr is discarded so credentials and provider diagnostics cannot enter the UI.
    static func run(bridge: URL, environment: [String: String]) async -> Bool {
        await Task.detached(priority: .utility) {
            runBlocking(bridge: bridge, environment: environment)
        }.value
    }

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
