import Darwin
import Foundation
import SQLite3
import XCTest
@testable import M3MCPApp

final class VoiceMemosSnapshotSecurityTests: XCTestCase {
    func testSnapshotUsesOwnerOnlyAnchoredCopiesAndCleansExactly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("CloudRecordings.db")
        let expected = Data("sqlite-fixture".utf8)
        try expected.write(to: source)

        let snapshot = try SecureVoiceMemoStoreSnapshot.create(
            sourceDatabase: source,
            temporaryDirectory: root
        )

        XCTAssertTrue(snapshot.validateBeforeOpen())
        XCTAssertEqual(try Data(contentsOf: snapshot.database), expected)
        XCTAssertEqual(try permissions(of: snapshot.directory), 0o700)
        XCTAssertEqual(try permissions(of: snapshot.database), 0o600)

        try snapshot.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.directory.path))
    }

    func testSnapshotAcceptsCanonicalizedDefaultMacOSTemporaryDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("CloudRecordings.db")
        try Data("sqlite-fixture".utf8).write(to: source)

        let snapshot = try SecureVoiceMemoStoreSnapshot.create(sourceDatabase: source)
        XCTAssertTrue(snapshot.validateBeforeOpen())
        XCTAssertEqual(
            snapshot.directory.deletingLastPathComponent().path,
            try canonicalPath(FileManager.default.temporaryDirectory)
        )
        try snapshot.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.directory.path))
    }

    func testSnapshotRejectsSymlinkSourceWithoutReadingTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("protected.db")
        let source = root.appendingPathComponent("CloudRecordings.db")
        try Data("do-not-copy".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)

        XCTAssertThrowsError(
            try SecureVoiceMemoStoreSnapshot.create(
                sourceDatabase: source,
                temporaryDirectory: root
            )
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "do-not-copy")
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).filter { $0.hasPrefix("M3MCP-VoiceMemos-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testReadOnlySQLiteOpenReplaysCopiedWAL() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("CloudRecordings.db")

        var writer: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                source.path,
                &writer,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                    | SQLITE_OPEN_NOFOLLOW,
                nil
            ),
            SQLITE_OK
        )
        guard let writer else {
            return XCTFail("Could not create synthetic WAL fixture")
        }
        defer { sqlite3_close(writer) }

        try execute("PRAGMA journal_mode=WAL", database: writer)
        try execute("PRAGMA wal_autocheckpoint=0", database: writer)
        try execute("CREATE TABLE fixture(value TEXT NOT NULL)", database: writer)
        try execute("INSERT INTO fixture VALUES ('visible-from-wal')", database: writer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path + "-shm"))

        let snapshot = try SecureVoiceMemoStoreSnapshot.create(
            sourceDatabase: source,
            temporaryDirectory: root
        )
        defer { try? snapshot.cleanup() }

        var reader: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            snapshot.database.path,
            &reader,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        XCTAssertEqual(openStatus, SQLITE_OK)
        guard let reader else {
            return XCTFail("Could not open copied WAL fixture read-only")
        }
        defer { sqlite3_close(reader) }

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(reader, "SELECT value FROM fixture", -1, &statement, nil),
            SQLITE_OK
        )
        guard let statement else {
            return XCTFail("Could not query copied WAL fixture")
        }
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "visible-from-wal")
        XCTAssertTrue(snapshot.validateAfterOpen())
        XCTAssertTrue(snapshot.validateAfterRead())
    }

    func testSnapshotRejectsInjectedSQLiteSidecar() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("CloudRecordings.db")
        try Data("sqlite-fixture".utf8).write(to: source)
        let snapshot = try SecureVoiceMemoStoreSnapshot.create(
            sourceDatabase: source,
            temporaryDirectory: root
        )
        defer { try? snapshot.cleanup() }

        try Data("injected".utf8).write(
            to: URL(fileURLWithPath: snapshot.database.path + "-wal")
        )
        XCTAssertFalse(snapshot.validateBeforeOpen())
    }

    func testSnapshotRejectsInPlaceDatabaseMutationWithStableInodeAndSize() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("CloudRecordings.db")
        try Data("trusted-copy".utf8).write(to: source)
        let snapshot = try SecureVoiceMemoStoreSnapshot.create(
            sourceDatabase: source,
            temporaryDirectory: root
        )
        defer { try? snapshot.cleanup() }

        var before = stat()
        XCTAssertEqual(lstat(snapshot.database.path, &before), 0)
        let descriptor = Darwin.open(snapshot.database.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        let replacement = Data("hostile-copy".utf8)
        XCTAssertEqual(replacement.count, Int(before.st_size))
        let written = replacement.withUnsafeBytes { bytes in
            Darwin.pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        XCTAssertEqual(written, replacement.count)
        XCTAssertEqual(fsync(descriptor), 0)

        var after = stat()
        XCTAssertEqual(lstat(snapshot.database.path, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertFalse(snapshot.validateBeforeOpen())
    }

    func testProviderRejectsMutationAtPostReadValidationBoundary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("CloudRecordings.db")
        var writer: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                source.path,
                &writer,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                    | SQLITE_OPEN_NOFOLLOW,
                nil
            ),
            SQLITE_OK
        )
        guard let writer else { return XCTFail("Could not create SQLite fixture") }
        try execute("CREATE TABLE fixture(value TEXT NOT NULL)", database: writer)
        try execute("INSERT INTO fixture VALUES ('trusted')", database: writer)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)

        let provider = VoiceMemosProvider()
        XCTAssertThrowsError(
            try provider.withDatabase(
                at: source,
                temporaryDirectory: root,
                postReadValidationHook: { snapshotURL in
                    let descriptor = Darwin.open(snapshotURL.path, O_WRONLY | O_CLOEXEC)
                    guard descriptor >= 0 else { return }
                    defer { Darwin.close(descriptor) }
                    var byte: UInt8 = 0x58
                    _ = Darwin.pwrite(descriptor, &byte, 1, 128)
                    _ = fsync(descriptor)
                },
                body: { database in
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(
                        database,
                        "SELECT value FROM fixture",
                        -1,
                        &statement,
                        nil
                    ) == SQLITE_OK, let statement else {
                        throw NSError(domain: "fixture", code: 1)
                    }
                    defer { sqlite3_finalize(statement) }
                    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
                    return String(cString: sqlite3_column_text(statement, 0))
                }
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("changed while SQLite read it"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testSnapshotRefusesReplacedParentAndCleanupDoesNotFollowReplacement() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("CloudRecordings.db")
        try Data("trusted-copy".utf8).write(to: source)
        let snapshot = try SecureVoiceMemoStoreSnapshot.create(
            sourceDatabase: source,
            temporaryDirectory: root
        )

        let moved = root.appendingPathComponent("moved-original", isDirectory: true)
        try FileManager.default.moveItem(at: snapshot.directory, to: moved)
        try FileManager.default.createDirectory(
            at: snapshot.directory,
            withIntermediateDirectories: false
        )
        let replacement = snapshot.directory.appendingPathComponent("CloudRecordings.db")
        try Data("replacement-must-survive".utf8).write(to: replacement)

        XCTAssertFalse(snapshot.validateBeforeOpen())
        try snapshot.cleanup()
        XCTAssertEqual(
            try String(contentsOf: replacement, encoding: .utf8),
            "replacement-must-survive"
        )
    }

    func testSnapshotRefusesReplacedTemporaryParentPath() throws {
        let root = try makeRoot()
        let movedRoot = URL(fileURLWithPath: root.path + "-moved", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }
        let source = root.appendingPathComponent("CloudRecordings.db")
        try Data("trusted-copy".utf8).write(to: source)
        let snapshot = try SecureVoiceMemoStoreSnapshot.create(
            sourceDatabase: source,
            temporaryDirectory: root
        )

        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: snapshot.directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let replacement = snapshot.database
        try Data("replacement-parent-must-survive".utf8).write(to: replacement)

        XCTAssertFalse(snapshot.validateBeforeOpen())
        try snapshot.cleanup()
        XCTAssertEqual(
            try String(contentsOf: replacement, encoding: .utf8),
            "replacement-parent-must-survive"
        )
    }

    private func makeRoot() throws -> URL {
        let root = URL(
            fileURLWithPath: "/private/tmp/m3-voice-snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func permissions(of url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return metadata.st_mode & 0o777
    }

    private func canonicalPath(_ url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.path.withCString { path in
            buffer.withUnsafeMutableBufferPointer {
                Darwin.realpath(path, $0.baseAddress) != nil
            }
        }
        guard resolved else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return String(cString: buffer)
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? "SQLite status \(status)"
            throw NSError(
                domain: "VoiceMemosSnapshotSecurityTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
