import Foundation

enum AppLogger {
    private static let logPath = "/tmp/m3mcpapp.log"

    static func log(_ message: String) {
        let line = "[M3MCP] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: URL(fileURLWithPath: logPath), atomically: true, encoding: .utf8)
        }
    }
}
