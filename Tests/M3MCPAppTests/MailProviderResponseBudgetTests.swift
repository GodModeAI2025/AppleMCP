import Darwin
import Foundation
import M3MCPCore
import SQLite3
import XCTest
@testable import M3MCPApp

final class MailProviderResponseBudgetTests: XCTestCase {
    func testListMailboxesBoundsWorstCaseJSONEscapingAndDisclosesTruncation() async throws {
        let fixture = try makeHostileMailFixture(mailboxCount: 1_000, messageCount: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await withMailRoot(fixture.root) {
            await MailProvider().listMailboxes(input: [:])
        }
        let encoded = try M3JSON.makeEncoder().encode(response)

        XCTAssertTrue(response.ok, response.message ?? "mailbox listing failed")
        XCTAssertGreaterThan(encoded.count, 5 * 1_024 * 1_024)
        XCTAssertLessThan(encoded.count, LocalHTTPResponseParser.maximumBodyBytes)
        XCTAssertLessThanOrEqual(encoded.count, MailProvider.maximumEncodedCollectionResponseBytes)
        XCTAssertLessThan(response.items.count, 1_000)
        XCTAssertEqual(response.meta?["returned"], String(response.items.count))
        XCTAssertEqual(response.meta?["total"], "1000")
        XCTAssertEqual(response.meta?["has_more"], "true")
        XCTAssertEqual(response.meta?["truncated"], "true")
        XCTAssertEqual(response.meta?["result_limit_capped"], "false")
        XCTAssertEqual(response.meta?["response_budget_capped"], "true")
        XCTAssertEqual(
            response.meta?["response_budget_bytes"],
            String(MailProvider.maximumEncodedCollectionResponseBytes)
        )
        XCTAssertTrue(response.message?.contains("byte budget") == true)

        // The budget omits whole rows; it never clips a retained mailbox to make it fit.
        XCTAssertFalse(response.items.isEmpty)
        XCTAssertTrue(response.items.allSatisfy { $0.metadata["url"]?.count == 4_096 })
    }

    func testMailboxRowScanCapIsDisclosedForListingAndFailsSearchClosed() async throws {
        let fixture = try makeHostileMailFixture(
            mailboxCount: MailProvider.maximumMailboxRows + 1,
            messageCount: 0,
            mailboxURL: "Inbox"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let listing = await withMailRoot(fixture.root) {
            await MailProvider().listMailboxes(input: [:])
        }

        XCTAssertTrue(listing.ok, listing.message ?? "mailbox listing failed")
        XCTAssertEqual(listing.meta?["total"], String(MailProvider.maximumMailboxRows))
        XCTAssertEqual(listing.meta?["total_exact"], "false")
        XCTAssertEqual(listing.meta?["scan_budget"], String(MailProvider.maximumMailboxRows))
        XCTAssertEqual(listing.meta?["scan_capped"], "true")
        XCTAssertEqual(listing.meta?["has_more"], "true")
        XCTAssertEqual(listing.meta?["truncated"], "true")
        XCTAssertTrue(listing.message?.contains("hard \(MailProvider.maximumMailboxRows)-row scan budget") == true)

        let search = await withMailRoot(fixture.root) {
            await MailProvider().search(input: ["auto_intent": .bool(false), "limit": .number(1)])
        }
        XCTAssertFalse(search.ok)
        XCTAssertTrue(search.items.isEmpty)
        XCTAssertTrue(search.message?.contains("hard row safety budget") == true)
    }

    func testSearchBoundsWorstCaseJSONEscapingAndKeepsPagingMetadataAccurate() async throws {
        let fixture = try makeHostileMailFixture(mailboxCount: 1, messageCount: 500)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await withMailRoot(fixture.root) {
            await MailProvider().search(input: [
                "query": .string(""),
                "limit": .number(500),
                "offset": .number(0),
                "auto_intent": .bool(false)
            ])
        }
        let encoded = try M3JSON.makeEncoder().encode(response)

        XCTAssertTrue(response.ok, response.message ?? "mail search failed")
        XCTAssertGreaterThan(encoded.count, 5 * 1_024 * 1_024)
        XCTAssertLessThan(encoded.count, LocalHTTPResponseParser.maximumBodyBytes)
        XCTAssertLessThanOrEqual(encoded.count, MailProvider.maximumEncodedCollectionResponseBytes)
        XCTAssertLessThan(response.items.count, 500)
        XCTAssertEqual(response.meta?["returned"], String(response.items.count))
        XCTAssertEqual(response.meta?["total"], "500")
        XCTAssertEqual(response.meta?["has_more"], "true")
        XCTAssertEqual(response.meta?["truncated"], "true")
        XCTAssertEqual(response.meta?["response_budget_capped"], "true")
        XCTAssertEqual(
            response.meta?["response_budget_bytes"],
            String(MailProvider.maximumEncodedCollectionResponseBytes)
        )
        XCTAssertTrue(
            response.message?.contains("offset \(response.items.count)") == true,
            response.message ?? "missing truncation message"
        )

        // Subjects, senders, and message ids are retained at their provider bounds. JSON escaping,
        // not partial field clipping, is what exercises the aggregate byte ceiling here.
        XCTAssertFalse(response.items.isEmpty)
        XCTAssertTrue(response.items.allSatisfy { item in
            item.title.count == 2_000
                && item.subtitle?.count == 2_000
                && item.metadata["message_id"]?.count == 2_000
        })
    }

    func testReadBoundsHostileRecipientHeaderAndReportsTruncation() async throws {
        let hostileRecipients = String(repeating: "\u{0001}", count: 1_500_000)
        let fixture = try makeReadableMailFixture(
            mailboxes: [(1, "Local.mbox")],
            messages: [(1, 1, 0)]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let messagesDirectory = fixture.root
            .appendingPathComponent("V10/Local.mbox/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        let emlx = "0\nTo: \(hostileRecipients)\nContent-Type: text/plain; charset=utf-8\n\nhello"
        try Data(emlx.utf8).write(to: messagesDirectory.appendingPathComponent("1.emlx"))

        let response = await withMailRoot(fixture.root) {
            await MailProvider().read(input: ["id": .string("1")])
        }
        let encoded = try M3JSON.makeEncoder().encode(response)

        XCTAssertTrue(response.ok, response.message ?? "mail read failed")
        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.items[0].metadata["recipients_truncated"], "true")
        XCTAssertEqual(
            response.items[0].metadata["to"]?.utf8.count,
            MailProvider.maximumReturnedRecipientUTF8Bytes
        )
        XCTAssertLessThanOrEqual(encoded.count, MailProvider.maximumEncodedCollectionResponseBytes)
        XCTAssertLessThan(encoded.count, LocalHTTPResponseParser.maximumBodyBytes)
    }

    func testDefaultSearchExcludesJunkMailboxEvenWhenMessageFlagIsClear() async throws {
        let fixture = try makeReadableMailFixture(
            mailboxes: [(1, "Inbox"), (2, "Junk")],
            messages: [(1, 1, 0), (2, 2, 0)]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let defaultResponse = await withMailRoot(fixture.root) {
            await MailProvider().search(input: ["auto_intent": .bool(false), "limit": .number(10)])
        }
        let optedInResponse = await withMailRoot(fixture.root) {
            await MailProvider().search(input: [
                "auto_intent": .bool(false),
                "include_junk": .bool(true),
                "limit": .number(10)
            ])
        }

        XCTAssertTrue(defaultResponse.ok, defaultResponse.message ?? "default search failed")
        XCTAssertEqual(defaultResponse.items.map(\.id), ["1"])
        XCTAssertTrue(optedInResponse.ok, optedInResponse.message ?? "opted-in search failed")
        XCTAssertEqual(Set(optedInResponse.items.map(\.id)), Set(["1", "2"]))
    }

    func testInvalidMatchAndFieldSelectorsFailInsteadOfFallingBack() async {
        let provider = MailProvider()
        let invalidMatch = await provider.search(input: ["match": .string("bogus")])
        let invalidFields = await provider.search(input: ["fields": .array([.string("boddy")])])

        XCTAssertFalse(invalidMatch.ok)
        XCTAssertTrue(invalidMatch.message?.contains("all, any, phrase") == true)
        XCTAssertFalse(invalidFields.ok)
        XCTAssertTrue(invalidFields.message?.contains("too large") == true)
    }

    private func withMailRoot<T>(
        _ root: URL,
        operation: () async throws -> T
    ) async rethrows -> T {
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

    private func makeHostileMailFixture(
        mailboxCount: Int,
        messageCount: Int,
        mailboxURL: String? = nil
    ) throws -> (root: URL, index: URL) {
        let root = URL(
            fileURLWithPath: "/private/tmp/m3mail-budget-\(UUID().uuidString)",
            isDirectory: true
        )
        let mailData = root.appendingPathComponent("V10/MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)

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
            CREATE TABLE messages (
                message_id TEXT,
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

        // U+0001 is legal SQLite text and is encoded as six JSON bytes (`\\u0001`). It therefore
        // exercises the expansion that character-count-only limits cannot account for.
        let hostileMailbox = mailboxURL ?? String(repeating: "\u{0001}", count: 4_096)
        try execute("BEGIN IMMEDIATE", on: database)
        do {
            try insertMailboxes(count: mailboxCount, url: hostileMailbox, into: database)

            if messageCount > 0 {
                let hostileField = String(repeating: "\u{0001}", count: 2_000)
                try insertMessages(count: messageCount, field: hostileField, into: database)
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }

        return (root, index)
    }

    private func makeReadableMailFixture(
        mailboxes: [(id: Int, url: String)],
        messages: [(id: Int, mailbox: Int, junk: Int)]
    ) throws -> (root: URL, index: URL) {
        let root = URL(
            fileURLWithPath: "/private/tmp/m3mail-readable-\(UUID().uuidString)",
            isDirectory: true
        )
        let mailData = root.appendingPathComponent("V10/MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)

        let index = mailData.appendingPathComponent("Envelope Index")
        var database: OpaquePointer?
        guard sqlite3_open(index.path, &database) == SQLITE_OK, let database else {
            throw fixtureError("could not create readable Envelope Index")
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE mailboxes (url TEXT, total_count INTEGER, unread_count INTEGER);
            CREATE TABLE messages (
                message_id TEXT,
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

        var mailboxStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO mailboxes (ROWID, url, total_count, unread_count) VALUES (?, ?, 0, 0)",
            -1,
            &mailboxStatement,
            nil
        ) == SQLITE_OK, let mailboxStatement else {
            throw fixtureError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(mailboxStatement) }
        for mailbox in mailboxes {
            sqlite3_bind_int64(mailboxStatement, 1, sqlite3_int64(mailbox.id))
            sqlite3_bind_text(mailboxStatement, 2, mailbox.url, -1, transientDestructor())
            guard sqlite3_step(mailboxStatement) == SQLITE_DONE else {
                throw fixtureError(String(cString: sqlite3_errmsg(database)))
            }
            sqlite3_reset(mailboxStatement)
            sqlite3_clear_bindings(mailboxStatement)
        }

        var messageStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO messages (ROWID, message_id, subject, sender, date_received, read, deleted, junk, mailbox) VALUES (?, ?, ?, 'sender', ?, 0, 0, ?, ?)",
            -1,
            &messageStatement,
            nil
        ) == SQLITE_OK, let messageStatement else {
            throw fixtureError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(messageStatement) }
        for message in messages {
            sqlite3_bind_int64(messageStatement, 1, sqlite3_int64(message.id))
            sqlite3_bind_text(messageStatement, 2, String(message.id), -1, transientDestructor())
            sqlite3_bind_text(messageStatement, 3, "message \(message.id)", -1, transientDestructor())
            sqlite3_bind_double(messageStatement, 4, Date().timeIntervalSince1970 - Double(message.id))
            sqlite3_bind_int(messageStatement, 5, Int32(message.junk))
            sqlite3_bind_int64(messageStatement, 6, sqlite3_int64(message.mailbox))
            guard sqlite3_step(messageStatement) == SQLITE_DONE else {
                throw fixtureError(String(cString: sqlite3_errmsg(database)))
            }
            sqlite3_reset(messageStatement)
            sqlite3_clear_bindings(messageStatement)
        }

        return (root, index)
    }

    private func insertMailboxes(count: Int, url: String, into database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO mailboxes (ROWID, url, total_count, unread_count) VALUES (?, ?, 0, 0)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw fixtureError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        for id in 1...count {
            sqlite3_bind_int64(statement, 1, sqlite3_int64(id))
            sqlite3_bind_text(statement, 2, url, -1, transientDestructor())
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw fixtureError(String(cString: sqlite3_errmsg(database)))
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    private func insertMessages(count: Int, field: String, into database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO messages
          (ROWID, message_id, subject, sender, date_received, read, deleted, junk, mailbox)
        VALUES (?, ?, ?, ?, ?, 0, 0, 0, 1)
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw fixtureError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        let now = Date().timeIntervalSince1970
        for id in 1...count {
            sqlite3_bind_int64(statement, 1, sqlite3_int64(id))
            sqlite3_bind_text(statement, 2, field, -1, transientDestructor())
            sqlite3_bind_text(statement, 3, field, -1, transientDestructor())
            sqlite3_bind_text(statement, 4, field, -1, transientDestructor())
            sqlite3_bind_double(statement, 5, now - Double(id))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw fixtureError(String(cString: sqlite3_errmsg(database)))
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
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
            domain: "MailProviderResponseBudgetTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
