import Darwin
import Foundation
import M3MCPCore
import SQLite3
import XCTest
@testable import M3MCPApp

final class MailProviderQuotedPrintableTests: XCTestCase {
    func testSoftLineBreaksAreRemoved() {
        let decoded = MailProvider.decodeQuotedPrintableBytes(
            "one=\r\ntwo=\nthree",
            maximumOutputBytes: 1_024
        )

        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "onetwothree")
    }

    func testValidEscapesDecodeAndInvalidEscapesRemainLiteral() {
        let decoded = MailProvider.decodeQuotedPrintableBytes(
            "A=20B=3dC=4a=G1=4Z=",
            maximumOutputBytes: 1_024
        )

        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "A B=CJ=G1=4Z=")
    }

    func testUTF8EscapesAreDecodedAsOneByteSequence() {
        XCTAssertEqual(
            MailProvider.decodeQuotedPrintableText(
                "=C3=A4",
                contentType: "text/plain; charset=\"UTF-8\"",
                maximumOutputBytes: 1_024
            ),
            "ä"
        )
    }

    func testDeclaredLegacyCharsetReceivesDecodedBytes() {
        XCTAssertEqual(
            MailProvider.decodeQuotedPrintableText(
                "=E4",
                contentType: "text/plain; charset=ISO-8859-1",
                maximumOutputBytes: 1_024
            ),
            "ä"
        )
    }

    func testManyEscapesDecodeDeterministically() {
        let count = 1_000_000
        let decoded = MailProvider.decodeQuotedPrintableBytes(
            String(repeating: "=41", count: count),
            maximumOutputBytes: count
        )

        XCTAssertEqual(decoded, Data(repeating: UInt8(ascii: "A"), count: count))
    }

    func testOutputByteLimitIsEnforced() {
        let decoded = MailProvider.decodeQuotedPrintableBytes(
            "=41=42=43=44=45",
            maximumOutputBytes: 4
        )

        XCTAssertEqual(decoded, Data("ABCD".utf8))
        XCTAssertTrue(MailProvider.decodeQuotedPrintableBytes("=41", maximumOutputBytes: 0).isEmpty)
    }

    func testMultipartSplittingStopsBeforeMaterializingAttackerControlledPartCount() {
        let body = String(repeating: "--x", count: 1_000_000)
        let parts = MailProvider.boundedComponents(of: body, separatedBy: "--x", limit: 128)

        XCTAssertEqual(parts.count, 128)
        XCTAssertTrue(parts.allSatisfy(\.isEmpty))
    }
}

final class MailProviderBodySearchTests: XCTestCase {
    func testMixedBodySearchDefersTermsButRetainsSQLFiltersAndCandidateMetadata() async throws {
        let fixture = try makeMailFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let environmentKey = MailProvider.mailRootEnvironmentKey
        let previousValue = getenv(environmentKey).map { String(cString: $0) }
        setenv(environmentKey, fixture.root.path, 1)
        defer {
            if let previousValue {
                setenv(environmentKey, previousValue, 1)
            } else {
                unsetenv(environmentKey)
            }
        }

        let commonInput: [String: JSONValue] = [
            "query": .string("bodyneedle"),
            "fields": .array([.string("subject"), .string("body")]),
            "unread_only": .bool(true),
            "since_hours": .number(24),
            "mailbox": .string("Inbox"),
            "auto_intent": .bool(false),
            "include_body": .bool(false)
        ]

        var completeInput = commonInput
        completeInput["limit"] = .number(10)
        completeInput["max_candidates"] = .number(10)
        let complete = await MailProvider().search(input: completeInput)

        XCTAssertTrue(complete.ok, complete.message ?? "mail search failed")
        XCTAssertEqual(complete.items.map(\.id), ["1", "7"])
        XCTAssertEqual(complete.items.map { $0.metadata["fields_matched"] }, ["body", "body"])
        XCTAssertTrue(complete.items.allSatisfy { $0.preview == nil })
        XCTAssertEqual(complete.meta?["scanned"], "2")
        XCTAssertEqual(complete.meta?["scan_capped"], "false")
        XCTAssertEqual(complete.meta?["total_exact"], "true")
        XCTAssertEqual(complete.meta?["truncated"], "false")
        XCTAssertEqual(complete.meta?["mailbox_filter_matched"], "1")

        var cappedInput = commonInput
        cappedInput["limit"] = .number(1)
        cappedInput["max_candidates"] = .number(1)
        let capped = await MailProvider().search(input: cappedInput)

        XCTAssertEqual(capped.items.map(\.id), ["1"])
        XCTAssertEqual(capped.meta?["scanned"], "1")
        XCTAssertEqual(capped.meta?["scan_capped"], "true")
        XCTAssertEqual(capped.meta?["total_exact"], "false")
        XCTAssertEqual(capped.meta?["truncated"], "true")
    }

    private func makeMailFixture() throws -> (root: URL, index: URL) {
        let root = URL(
            fileURLWithPath: "/private/tmp/m3mail-\(UUID().uuidString)",
            isDirectory: true
        )
        let versionRoot = root.appendingPathComponent("V10", isDirectory: true)
        let mailData = versionRoot.appendingPathComponent("MailData", isDirectory: true)
        let inboxMessages = versionRoot.appendingPathComponent("Mailboxes/Inbox/Messages", isDirectory: true)
        let archiveMessages = versionRoot.appendingPathComponent("Mailboxes/Archive/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inboxMessages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveMessages, withIntermediateDirectories: true)

        let index = mailData.appendingPathComponent("Envelope Index")
        var database: OpaquePointer?
        guard sqlite3_open(index.path, &database) == SQLITE_OK, let database else {
            throw fixtureError("could not create synthetic Envelope Index")
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE mailboxes (
                url TEXT,
                total_count INTEGER,
                unread_count INTEGER
            );
            INSERT INTO mailboxes (ROWID, url, total_count, unread_count) VALUES
                (1, 'Mailboxes/Inbox', 6, 4),
                (2, 'Mailboxes/Archive', 1, 1);

            CREATE TABLE messages (
                subject TEXT,
                sender TEXT,
                date_received REAL,
                read INTEGER,
                deleted INTEGER,
                junk INTEGER,
                mailbox INTEGER
            );
            """,
            on: database
        )

        let now = Date().timeIntervalSince1970
        let rows: [(Int, Double, Int, Int, Int, Int)] = [
            (1, now - 60, 0, 0, 0, 1),       // desired newest eligible hit
            (2, now + 600, 0, 0, 1, 1),      // junk
            (3, now + 500, 1, 0, 0, 1),      // read
            (4, now + 400, 0, 1, 0, 1),      // deleted
            (5, now + 300, 0, 0, 0, 2),      // different mailbox
            (6, now - 172_800, 0, 0, 0, 1),  // outside since_hours
            (7, now - 120, 0, 0, 0, 1)       // second eligible hit proves the cap
        ]
        for (id, date, read, deleted, junk, mailbox) in rows {
            try execute(
                """
                INSERT INTO messages (ROWID, subject, sender, date_received, read, deleted, junk, mailbox)
                VALUES (\(id), 'unrelated subject \(id)', 'sender@example.test', \(date), \(read), \(deleted), \(junk), \(mailbox));
                """,
                on: database
            )

            let messages = mailbox == 1 ? inboxMessages : archiveMessages
            let email = """
            Content-Type: text/plain; charset=utf-8\r
            Content-Transfer-Encoding: quoted-printable\r
            \r
            bodyneedle appears only in the message body\r
            """
            let emlx = "\(email.utf8.count)\n\(email)"
            try Data(emlx.utf8).write(to: messages.appendingPathComponent("\(id).emlx"))
        }

        return (root, index)
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw fixtureError(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "MailProviderBodySearchTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
