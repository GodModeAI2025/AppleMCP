import Foundation
import SQLite3

struct SQLiteStoreFailure: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Reads a live SQLite store without writing to it.
///
/// Voice Memos keeps `CloudRecordings.db` in WAL mode and the write-ahead log routinely
/// dwarfs the main database — 844 KB against 106 KB on a typical store. Opening the original
/// read-only is not viable: SQLite either fails to initialise the `-shm` (`SQLITE_READONLY_CANTINIT`)
/// or, with `immutable=1`, silently ignores the WAL and hands back a database missing the most
/// recent recordings. Copying the whole trio and opening the copy read-write lets SQLite replay
/// the log while the live store stays untouched.
enum SQLiteSnapshot {
    /// Suffixes copied alongside the main database file. The main file is required; the others
    /// are absent whenever SQLite has already checkpointed.
    private static let companionSuffixes = ["-wal", "-shm"]

    static func withDatabase<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("m3mcp-snapshot-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SQLiteStoreFailure("Could not create a scratch directory for the database snapshot: \(error.localizedDescription)")
        }

        defer { try? fileManager.removeItem(at: directory) }

        let snapshot = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try fileManager.copyItem(at: url, to: snapshot)
        } catch {
            // Foundation phrases a denied read as a failure to access the *destination*, which
            // points at the scratch directory and reads as nonsense. Name the source instead.
            throw SQLiteStoreFailure("Cannot read \(url.path). Grant Full Disk Access to M3MCP, then restart the app.")
        }

        for suffix in companionSuffixes {
            let companion = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: companion.path) else { continue }
            // A missing companion is normal; a failed copy is not fatal either, since SQLite can
            // still open the main file. Losing the WAL would hide recent rows, so it is worth trying.
            try? fileManager.copyItem(at: companion, to: URL(fileURLWithPath: snapshot.path + suffix))
        }

        var database: OpaquePointer?
        // Read-write on purpose: the copy is disposable, and SQLite needs write access to replay
        // the WAL into it. The original is never opened.
        let status = sqlite3_open_v2(snapshot.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)

        guard status == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "OSStatus \(status)"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteStoreFailure("Could not open the database snapshot. Detail: \(detail)")
        }

        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 800)
        return try body(database)
    }

    static func tableColumns(database: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    static func double(_ statement: OpaquePointer, column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    static func blobHex(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        let buffer = UnsafeRawBufferPointer(start: bytes, count: count)
        return buffer.map { String(format: "%02x", $0) }.joined()
    }
}
