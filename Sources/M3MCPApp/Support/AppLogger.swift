import Foundation
import OSLog

enum AppLogger {
    /// Application diagnostics can contain local paths, Voice Memo filenames, and framework error
    /// strings. Keep them in Unified Logging as private data instead of appending to a predictable
    /// file in the world-writable `/tmp` directory.
    private static let logger = Logger(subsystem: "de.markzimmermann.m3mcp", category: "application")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .private(mask: .hash))")
    }
}
