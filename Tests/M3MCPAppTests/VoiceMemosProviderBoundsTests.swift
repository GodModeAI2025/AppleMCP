import Foundation
import M3MCPCore
import SQLite3
import XCTest
@testable import M3MCPApp

final class VoiceMemosProviderBoundsTests: XCTestCase {
    func testTranscribeRejectsTimeoutOutsideSharedRuntimeRange() async {
        let provider = VoiceMemosProvider()

        for value in [
            VoiceMemoTranscriptionTimeoutPolicy.minimumSeconds - 1,
            VoiceMemoTranscriptionTimeoutPolicy.maximumSeconds + 1
        ] {
            let response = await provider.transcribe(input: [
                "id": .string("1"),
                "timeout_seconds": .number(Double(value))
            ])

            XCTAssertFalse(response.ok)
            XCTAssertTrue(response.message?.contains("timeout_seconds must be between") == true)
        }
    }

    func testBoundedSegmentsMetadataAlwaysRemainsValidJSON() throws {
        let provider = VoiceMemosProvider()
        let segments = (0..<1_000).map { index in
            VoiceMemoTranscript.Segment(
                text: "segment-\(index)-" + String(repeating: "\u{0001}", count: 80),
                start: Double(index),
                end: Double(index + 1)
            )
        }

        let encoded = try XCTUnwrap(provider.encodeSegments(segments, maximumBytes: 1_000))
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(encoded.json.utf8)) as? [[String: Any]]
        )

        XCTAssertEqual(decoded.count, encoded.returned)
        XCTAssertLessThan(encoded.returned, segments.count)
        XCTAssertTrue(encoded.truncated)
        XCTAssertLessThanOrEqual(encoded.json.utf8.count, 1_000)
    }

    func testSearchRejectsQueryBeforeCaseNormalizationCanDuplicateIt() async {
        let provider = VoiceMemosProvider()
        let oversized = String(
            repeating: "é",
            count: VoiceMemosProvider.maximumQueryUTF8Bytes / 2 + 1
        )

        let response = await provider.search(input: ["query": .string(oversized)])

        XCTAssertFalse(response.ok)
        XCTAssertEqual(
            response.message,
            "query must not exceed \(VoiceMemosProvider.maximumQueryUTF8Bytes) UTF-8 bytes."
        )
    }

    func testCorruptSQLiteTextIsRejectedBeforeUnboundedSwiftStringCreation() async throws {
        let fixture = try makeStoreFixture(
            label: String(
                repeating: "x",
                count: VoiceMemoSQLiteValuePolicy.maximumLabelBytes + 1
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = VoiceMemosProvider(
            storeOverrideForTesting: (
                recordings: fixture.recordings,
                database: fixture.database
            )
        )

        let response = await provider.search(input: [:])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("ZCUSTOMLABEL") == true)
        XCTAssertTrue(
            response.message?.contains(
                "maximum is \(VoiceMemoSQLiteValuePolicy.maximumLabelBytes)"
            ) == true
        )
    }

    func testConnectionLengthLimitRejectsHugeCorruptSQLiteRow() async throws {
        let fixture = try makeStoreFixture(
            label: String(
                repeating: "z",
                count: VoiceMemoSQLiteValuePolicy.maximumSQLiteValueBytes + 1
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = VoiceMemosProvider(
            storeOverrideForTesting: (
                recordings: fixture.recordings,
                database: fixture.database
            )
        )

        let response = await provider.search(input: [:])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("bounded Voice Memos rows") == true)
    }

    func testMetadataOutputUsesUTF8ByteBounds() {
        let value = String(
            repeating: "é",
            count: VoiceMemosProvider.maximumMetadataLabelBytes
        )
        let bounded = VoiceMemosProvider.boundedOutput(
            value,
            maximumBytes: VoiceMemosProvider.maximumMetadataLabelBytes
        )

        XCTAssertLessThanOrEqual(
            bounded.utf8.count,
            VoiceMemosProvider.maximumMetadataLabelBytes
        )
        XCTAssertLessThan(bounded.utf8.count, value.utf8.count)
    }

    private func makeStoreFixture(
        label: String
    ) throws -> (root: URL, recordings: URL, database: URL) {
        let root = URL(
            fileURLWithPath: "/private/tmp/M3MCP-Voice-Bounds-\(UUID().uuidString)",
            isDirectory: true
        )
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordings,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let databaseURL = recordings.appendingPathComponent("CloudRecordings.db")

        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite("open")
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(
            database,
            "CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZPATH TEXT, ZCUSTOMLABEL TEXT)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw FixtureError.sqlite("create")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO ZCLOUDRECORDING (Z_PK, ZPATH, ZCUSTOMLABEL) VALUES (1, 'missing.m4a', ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw FixtureError.sqlite("prepare")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, label, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureError.sqlite("insert")
        }

        return (root, recordings, databaseURL)
    }
}

private enum FixtureError: Error {
    case sqlite(String)
}
