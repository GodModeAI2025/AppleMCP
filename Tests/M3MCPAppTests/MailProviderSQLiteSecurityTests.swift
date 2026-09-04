import Darwin
import Foundation
import M3MCPCore
import SQLite3
import XCTest
@testable import M3MCPApp

final class MailProviderSQLiteSecurityTests: XCTestCase {
    func testConnectionLengthLimitAndAccessorRejectOversizedText() throws {
        try withSQLiteValue(Array(repeating: 0x61, count: MailSQLiteValuePolicy.maximumSQLiteValueBytes + 1)) {
            database, statement in
            XCTAssertGreaterThan(
                Int(sqlite3_limit(database, SQLITE_LIMIT_LENGTH, -1)),
                MailSQLiteValuePolicy.maximumSQLiteValueBytes
            )
            XCTAssertThrowsError(
                try MailSQLiteValuePolicy.text(statement, column: 0, field: "hostile")
            ) { error in
                XCTAssertEqual(
                    error as? MailSQLiteValuePolicy.Violation,
                    .oversized(
                        field: "hostile",
                        bytes: MailSQLiteValuePolicy.maximumSQLiteValueBytes + 1,
                        maximum: MailSQLiteValuePolicy.maximumSQLiteValueBytes
                    )
                )
            }

            MailSQLiteValuePolicy.applyConnectionLimit(to: database)
            XCTAssertEqual(
                Int(sqlite3_limit(database, SQLITE_LIMIT_LENGTH, -1)),
                MailSQLiteValuePolicy.maximumSQLiteValueBytes
            )
        }
    }

    func testAccessorRejectsEmbeddedNULWithoutCStyleTruncation() throws {
        try withSQLiteValue([0x61, 0x00, 0x62]) { _, statement in
            XCTAssertThrowsError(
                try MailSQLiteValuePolicy.text(statement, column: 0, field: "nul")
            ) { error in
                XCTAssertEqual(
                    error as? MailSQLiteValuePolicy.Violation,
                    .embeddedNUL(field: "nul")
                )
            }
        }
    }

    func testAccessorRejectsInvalidUTF8InsteadOfRepairingIt() throws {
        try withSQLiteValue([0xC3, 0x28]) { _, statement in
            XCTAssertThrowsError(
                try MailSQLiteValuePolicy.text(statement, column: 0, field: "utf8")
            ) { error in
                XCTAssertEqual(
                    error as? MailSQLiteValuePolicy.Violation,
                    .invalidText(field: "utf8")
                )
            }
        }
    }

    func testRecipientJoinFailsClosedAtGlobalRowBudget() async throws {
        let fixture = try makeRecipientFixture(
            matchingRows: MailProvider.maximumRecipientJoinRows + 1,
            unmatchedRows: 0,
            indexMessageColumn: true
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let response = await withMailRoot(fixture) {
            await MailProvider().search(input: [
                "query": .string(""),
                "fields": .array([.string("recipients")]),
                "include_recipients": .bool(true),
                "auto_intent": .bool(false),
                "limit": .number(1)
            ])
        }

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.items.isEmpty)
        XCTAssertTrue(response.message?.contains("hard row safety budget") == true, response.message ?? "")
        XCTAssertTrue(response.message?.contains(String(MailProvider.maximumRecipientJoinRows)) == true)
    }

    func testRecipientJoinFailsClosedAtGlobalVMWorkBudget() async throws {
        let fixture = try makeRecipientFixture(
            matchingRows: 0,
            unmatchedRows: 500_000,
            indexMessageColumn: false
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let response = await withMailRoot(fixture) {
            await MailProvider().search(input: [
                "query": .string(""),
                "fields": .array([.string("recipients")]),
                "include_recipients": .bool(true),
                "auto_intent": .bool(false),
                "limit": .number(1)
            ])
        }

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.items.isEmpty)
        XCTAssertTrue(response.message?.contains("hard work safety budget") == true, response.message ?? "")
        XCTAssertTrue(response.message?.contains(String(MailProvider.maximumRecipientJoinVMInstructions)) == true)
    }

    private func withSQLiteValue(
        _ bytes: [UInt8],
        operation: (OpaquePointer, OpaquePointer) throws -> Void
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
            throw fixtureError("could not open in-memory SQLite database")
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT ?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw fixtureError("could not prepare SQLite value statement")
        }
        defer { sqlite3_finalize(statement) }

        let bindStatus = bytes.withUnsafeBytes { rawBytes -> Int32 in
            sqlite3_bind_text(
                statement,
                1,
                rawBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                Int32(rawBytes.count),
                transientDestructor()
            )
        }
        guard bindStatus == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw fixtureError("could not expose synthetic SQLite text")
        }
        try operation(database, statement)
    }

    private func makeRecipientFixture(
        matchingRows: Int,
        unmatchedRows: Int,
        indexMessageColumn: Bool
    ) throws -> URL {
        let root = URL(
            fileURLWithPath: "/private/tmp/m3mail-sqlite-security-\(UUID().uuidString)",
            isDirectory: true
        )
        let mailData = root.appendingPathComponent("V10/MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)

        var database: OpaquePointer?
        guard sqlite3_open(mailData.appendingPathComponent("Envelope Index").path, &database) == SQLITE_OK,
              let database else {
            throw fixtureError("could not create synthetic Envelope Index")
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE mailboxes (url TEXT, total_count INTEGER, unread_count INTEGER);
            INSERT INTO mailboxes (ROWID, url, total_count, unread_count) VALUES (1, 'Inbox', 1, 1);
            CREATE TABLE messages (
                message_id TEXT, subject TEXT, sender INTEGER, date_received REAL,
                read INTEGER, deleted INTEGER, junk INTEGER, mailbox INTEGER
            );
            INSERT INTO messages
                (ROWID, message_id, subject, sender, date_received, read, deleted, junk, mailbox)
            VALUES (1, 'one', 'one', 1, 1, 0, 0, 0, 1);
            CREATE TABLE addresses (address TEXT, comment TEXT);
            INSERT INTO addresses (ROWID, address, comment) VALUES (1, 'person@example.test', 'Person');
            CREATE TABLE recipients (message INTEGER, address INTEGER);
            """,
            on: database
        )
        if indexMessageColumn {
            try execute("CREATE INDEX recipients_message_index ON recipients(message);", on: database)
        }

        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw fixtureError("could not begin recipient fixture transaction")
        }
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO recipients (message, address) VALUES (?, 1)",
            -1,
            &insert,
            nil
        ) == SQLITE_OK, let insert else {
            throw fixtureError("could not prepare recipient fixture insertion")
        }
        defer { sqlite3_finalize(insert) }

        for index in 0..<(matchingRows + unmatchedRows) {
            sqlite3_bind_int(insert, 1, index < matchingRows ? 1 : 2)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw fixtureError("could not insert recipient fixture row")
            }
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw fixtureError("could not commit recipient fixture")
        }
        return root
    }

    private func withMailRoot<T>(_ root: URL, operation: () async throws -> T) async rethrows -> T {
        let key = MailProvider.mailRootEnvironmentKey
        let previousValue = getenv(key).map { String(cString: $0) }
        setenv(key, root.path, 1)
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }
        return try await operation()
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw fixtureError(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func transientDestructor() -> sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(
            domain: "MailProviderSQLiteSecurityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
