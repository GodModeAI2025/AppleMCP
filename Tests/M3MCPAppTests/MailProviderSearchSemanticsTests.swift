import Foundation
import M3MCPCore
import SQLite3
import XCTest
@testable import M3MCPApp

/// What `mail_search` actually matches, measured against a synthetic Envelope Index.
///
/// The provider reads a real SQLite database, a real `subjects`/`addresses`/`recipients` schema, and
/// real `.emlx` files on disk. Only the location is redirected, through the same environment
/// override the existing Mail tests use. Nothing here needs Full Disk Access or a Mail account, so
/// it runs everywhere the rest of the suite runs.
final class MailProviderSearchSemanticsTests: XCTestCase {
    private var fixture: MailFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try MailFixture()
    }

    override func tearDownWithError() throws {
        fixture?.tearDown()
        fixture = nil
        try super.tearDownWithError()
    }

    private func search(_ overrides: [String: JSONValue]) async -> ToolResponse {
        var input: [String: JSONValue] = [
            // The intent parser rewrites the query from its own wording. Off, so these assertions
            // are about matching and not about parsing.
            "auto_intent": .bool(false),
            "limit": .number(50),
            "max_candidates": .number(500)
        ]
        for (key, value) in overrides {
            input[key] = value
        }
        return await fixture.withMailRoot { await MailProvider().search(input: input) }
    }

    // MARK: - Term semantics

    func testAllRequiresEveryTermAndAnyRequiresOnlyOne() async {
        let all = await search([
            "query": .string("quarterly invoice"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertTrue(all.ok, all.message ?? "")
        XCTAssertEqual(all.items.map(\.id), ["1"])

        // One term in one message, the other in a different one. Neither message holds both.
        let noneHoldBoth = await search([
            "query": .string("quarterly travel"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertTrue(noneHoldBoth.items.isEmpty, "match=all must not join terms across messages")

        let any = await search([
            "query": .string("quarterly travel"),
            "match": .string("any"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(Set(any.items.map(\.id)), ["1", "3"])
    }

    func testPhraseKeepsTheWordOrderThatAllThrowsAway() async {
        let phrase = await search([
            "query": .string("quarterly invoice"),
            "match": .string("phrase"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(phrase.items.map(\.id), ["1"])

        let reversed = await search([
            "query": .string("invoice quarterly"),
            "match": .string("phrase"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertTrue(reversed.items.isEmpty, "a phrase is one string, not a set of words")

        // The same reversed words under match=all still match, which is the whole point of having
        // both modes.
        let reorderedTerms = await search([
            "query": .string("invoice quarterly"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(reorderedTerms.items.map(\.id), ["1"])
    }

    func testAnUnknownMatchModeIsRefusedRatherThanSilentlyTreatedAsAll() async {
        let response = await search([
            "query": .string("invoice"),
            "match": .string("regex")
        ])
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("all, any, phrase") == true, response.message ?? "")
    }

    // MARK: - Fields

    func testAnAddressBehindADisplayNameStaysSearchable() async {
        // The address is only in `addresses.address`; the display name is in `addresses.comment`.
        // Matching on the displayed string alone would make this address unfindable.
        let byAddress = await search([
            "query": .string("anna.beispiel@example.test"),
            "fields": .array([.string("sender")])
        ])
        XCTAssertEqual(byAddress.items.map(\.id), ["1"])
        XCTAssertEqual(byAddress.items.first?.metadata["fields_matched"], "sender")

        let byDisplayName = await search([
            "query": .string("Anna Beispiel"),
            "fields": .array([.string("sender")])
        ])
        XCTAssertEqual(byDisplayName.items.map(\.id), ["1"])
    }

    func testRecipientsAreSearchedThroughTheirOwnTable() async {
        let response = await search([
            "query": .string("carla@example.test"),
            "fields": .array([.string("recipients")])
        ])
        XCTAssertEqual(response.items.map(\.id), ["2"])
        XCTAssertEqual(response.items.first?.metadata["fields_matched"], "recipients")

        // And the same term is not found when recipients are not among the requested fields.
        let scoped = await search([
            "query": .string("carla@example.test"),
            "fields": .array([.string("subject"), .string("sender")])
        ])
        XCTAssertTrue(scoped.items.isEmpty, "a field the caller did not ask for must not be matched")
    }

    func testABodyOnlyHitSurvivesBeingAskedForAlongsideASubject() async {
        // The body is not in the index, so a term predicate built from the index-backed fields alone
        // would have decided this message was not a candidate before its .emlx was ever opened.
        let response = await search([
            "query": .string("bodyneedle"),
            "fields": .array([.string("subject"), .string("body")])
        ])
        XCTAssertEqual(response.items.map(\.id), ["3"])
        XCTAssertEqual(response.items.first?.metadata["fields_matched"], "body")
        XCTAssertEqual(response.meta?["total_exact"], "true")
    }

    func testFieldsOutsideTheDocumentedFourAreRefused() async {
        let response = await search([
            "query": .string("invoice"),
            "fields": .array([.string("headers")])
        ])
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("documented four names") == true, response.message ?? "")
    }

    // MARK: - Structural filters

    func testUnreadJunkAndDeletedAreFilteredInSQL() async {
        let everything = await search([
            "query": .string("newsletter"),
            "fields": .array([.string("subject")]),
            "include_junk": .bool(true)
        ])
        // Row 6 is deleted and must never appear, junk or not.
        XCTAssertEqual(Set(everything.items.map(\.id)), ["4", "5"])

        let withoutJunk = await search([
            "query": .string("newsletter"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(withoutJunk.items.map(\.id), ["4"])

        let unreadOnly = await search([
            "query": .string("newsletter"),
            "fields": .array([.string("subject")]),
            "include_junk": .bool(true),
            "unread_only": .bool(true)
        ])
        XCTAssertEqual(unreadOnly.items.map(\.id), ["5"])
    }

    func testSinceHoursUnderstandsBothDateEncodingsInOneStore() async {
        // Mail has written this column as a Unix epoch and as a Core Foundation reference date
        // depending on the schema version. Reading one of them as the other puts every message
        // decades out of range, and the filter then quietly returns nothing.
        let recent = await search([
            "query": .string("timestamp"),
            "fields": .array([.string("subject")]),
            "since_hours": .number(24)
        ])
        XCTAssertEqual(Set(recent.items.map(\.id)), ["7", "8"], "one row is epoch-dated, the other reference-dated")

        let all = await search([
            "query": .string("timestamp"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(Set(all.items.map(\.id)), ["7", "8", "9", "10"])
    }

    func testTheMailboxFilterReportsHowManyMailboxesItMatched() async {
        let response = await search([
            "query": .string("quarterly"),
            "fields": .array([.string("subject")]),
            "mailbox": .string("Archive")
        ])
        XCTAssertTrue(response.items.isEmpty, "message 1 is in the Inbox, not the Archive")
        XCTAssertEqual(response.meta?["mailbox_filter_matched"], "1")

        let unmatched = await search([
            "query": .string("quarterly"),
            "fields": .array([.string("subject")]),
            "mailbox": .string("no-such-mailbox")
        ])
        XCTAssertTrue(unmatched.items.isEmpty)
        XCTAssertEqual(unmatched.meta?["mailbox_filter_matched"], "0")
    }

    // MARK: - Reading one message

    func testReadingAMessageReturnsTheTextPartOfAMultipartBody() async {
        let response = await fixture.withMailRoot {
            await MailProvider().read(input: ["id": .string("11")])
        }

        XCTAssertTrue(response.ok, response.message ?? "")
        let item = try? XCTUnwrap(response.items.first)
        XCTAssertEqual(item?.title, "Multipart message")
        XCTAssertEqual(item?.metadata["mailbox_role"], "inbox")
        XCTAssertTrue(item?.preview?.contains("plain text part") == true, item?.preview ?? "")
        XCTAssertFalse(item?.preview?.contains("<b>") == true, "the HTML alternative must not win")
    }

    func testAMailboxPointingOutsideTheStoreDoesNotYieldAFileFromOutsideIt() async {
        let response = await fixture.withMailRoot {
            await MailProvider().read(input: ["id": .string("12")])
        }

        // The row is readable, because it is in the index. Its body is not, because the mailbox url
        // resolves outside the mail root and the .emlx candidate is rejected there.
        XCTAssertTrue(response.ok, response.message ?? "")
        let preview = response.items.first?.preview ?? ""
        XCTAssertFalse(
            preview.contains("secret-outside-the-store"),
            "a mailbox url that leaves the mail root must not read a file from outside it"
        )
    }

    func testANonNumericRowIdIsRefusedBeforeTheStoreIsOpened() async {
        for id in ["../../etc/passwd", "1; DROP TABLE messages", "01", "as:legacy"] {
            let response = await fixture.withMailRoot {
                await MailProvider().read(input: ["id": .string(id)])
            }
            XCTAssertFalse(response.ok, id)
        }
    }

    // MARK: - Mailbox descriptions

    func testMailboxUrlsAreSplitIntoAccountPathAndRole() {
        let imap = MailProvider.describeMailbox(
            url: "imap://alice%40example.test@mail.example.test/INBOX"
        )
        // The user component is percent-decoded, so an address-shaped user name produces an account
        // string with two '@'. Pinned as it is: this value is shown, never parsed again.
        XCTAssertEqual(imap.account, "alice@example.test@mail.example.test")
        XCTAssertEqual(imap.path, "INBOX")
        XCTAssertEqual(imap.name, "INBOX")
        XCTAssertEqual(imap.role, "inbox")

        let nested = MailProvider.describeMailbox(url: "Mailboxes/Archive/2019/Invoices")
        XCTAssertEqual(nested.account, "")
        XCTAssertEqual(nested.name, "Invoices")
        XCTAssertEqual(nested.path, "Mailboxes/Archive/2019/Invoices")
        XCTAssertEqual(nested.role, "folder", "only the leaf name decides the role")

        // German mailbox names are named roles too, which is what the junk and trash filters read.
        XCTAssertEqual(MailProvider.describeMailbox(url: "Mailboxes/Papierkorb").role, "trash")
        XCTAssertEqual(MailProvider.describeMailbox(url: "Mailboxes/Gesendet").role, "sent")
        XCTAssertEqual(MailProvider.describeMailbox(url: "Mailboxes/Werbung").role, "junk")

        let encoded = MailProvider.describeMailbox(url: "imap://mail.example.test/Gel%C3%B6schte%20Objekte")
        XCTAssertEqual(encoded.name, "Gelöschte Objekte")
        XCTAssertEqual(encoded.role, "trash")

        let empty = MailProvider.describeMailbox(url: "")
        XCTAssertEqual(empty.name, "")
        XCTAssertEqual(empty.role, "folder")
    }
}

/// A synthetic Mail store: an Envelope Index with the lookup-table schema, `.emlx` files on disk,
/// and one mailbox that deliberately points out of the store.
private final class MailFixture {
    let root: URL
    private let outside: URL

    init() throws {
        let unique = UUID().uuidString
        root = URL(fileURLWithPath: "/private/tmp/m3mail-semantics-\(unique)", isDirectory: true)
        outside = URL(fileURLWithPath: "/private/tmp/m3mail-outside-\(unique)", isDirectory: true)

        let version = root.appendingPathComponent("V10", isDirectory: true)
        let mailData = version.appendingPathComponent("MailData", isDirectory: true)
        let inbox = version.appendingPathComponent("Mailboxes/Inbox/Messages", isDirectory: true)
        let archive = version.appendingPathComponent("Mailboxes/Archive/Messages", isDirectory: true)
        let outsideMessages = outside.appendingPathComponent("Messages", isDirectory: true)

        let manager = FileManager.default
        try manager.createDirectory(at: mailData, withIntermediateDirectories: true)
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try manager.createDirectory(at: archive, withIntermediateDirectories: true)
        try manager.createDirectory(at: outsideMessages, withIntermediateDirectories: true)

        // The escape route: a symlink inside the store pointing at a directory outside it.
        try manager.createSymbolicLink(
            at: version.appendingPathComponent("Mailboxes/Escape", isDirectory: true),
            withDestinationURL: outside
        )

        try Self.write(
            body: "secret-outside-the-store",
            to: outsideMessages.appendingPathComponent("12.emlx")
        )
        try Self.write(
            body: "bodyneedle appears only in the message body",
            to: inbox.appendingPathComponent("3.emlx")
        )
        try Self.writeMultipart(to: inbox.appendingPathComponent("11.emlx"))

        var database: OpaquePointer?
        guard sqlite3_open(mailData.appendingPathComponent("Envelope Index").path, &database) == SQLITE_OK,
              let database else {
            throw Self.error("could not create the synthetic Envelope Index")
        }
        defer { sqlite3_close(database) }
        try Self.populate(database)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    /// Redirects the provider's store location for the duration of one call.
    func withMailRoot<T>(_ operation: () async throws -> T) async rethrows -> T {
        let key = MailProvider.mailRootEnvironmentKey
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, root.path, 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        return try await operation()
    }

    private static func write(body: String, to url: URL) throws {
        let email = """
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(body)\r
        """
        try Data("\(email.utf8.count)\n\(email)".utf8).write(to: url)
    }

    private static func writeMultipart(to url: URL) throws {
        let email = """
        Content-Type: multipart/alternative; boundary="frontier"\r
        \r
        --frontier\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        This is the plain text part.\r
        --frontier\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><b>html part</b></body></html>\r
        --frontier--\r
        """
        try Data("\(email.utf8.count)\n\(email)".utf8).write(to: url)
    }

    private static func populate(_ database: OpaquePointer) throws {
        let epochNow = Date().timeIntervalSince1970
        let referenceNow = Date().timeIntervalSinceReferenceDate

        try execute(
            """
            CREATE TABLE mailboxes (url TEXT, total_count INTEGER, unread_count INTEGER);
            INSERT INTO mailboxes (ROWID, url, total_count, unread_count) VALUES
                (1, 'Mailboxes/Inbox', 11, 4),
                (2, 'Mailboxes/Archive', 1, 0),
                (3, 'Mailboxes/Escape', 1, 0);

            CREATE TABLE subjects (subject TEXT);
            INSERT INTO subjects (ROWID, subject) VALUES
                (1, 'Quarterly invoice draft'),
                (2, 'Rechnung Q3'),
                (3, 'Travel plan'),
                (4, 'Weekly newsletter'),
                (5, 'Junk newsletter'),
                (6, 'Deleted newsletter'),
                (7, 'timestamp epoch recent'),
                (8, 'timestamp reference recent'),
                (9, 'timestamp epoch old'),
                (10, 'timestamp reference old'),
                (11, 'Multipart message'),
                (12, 'Message behind a symlink');

            CREATE TABLE addresses (address TEXT, comment TEXT);
            INSERT INTO addresses (ROWID, address, comment) VALUES
                (1, 'anna.beispiel@example.test', 'Anna Beispiel'),
                (2, 'bob@example.test', 'Bob'),
                (3, 'carla@example.test', NULL);

            CREATE TABLE messages (
                message_id TEXT,
                subject INTEGER,
                sender INTEGER,
                date_received REAL,
                read INTEGER,
                deleted INTEGER,
                junk INTEGER,
                mailbox INTEGER
            );

            CREATE TABLE recipients (message INTEGER, address INTEGER);
            INSERT INTO recipients (message, address) VALUES (2, 3), (1, 2);
            """,
            on: database
        )

        // (rowid, subject, sender, date, read, deleted, junk, mailbox)
        let rows: [(Int, Int, Int, Double, Int, Int, Int, Int)] = [
            (1, 1, 1, epochNow - 60, 0, 0, 0, 1),
            (2, 2, 2, epochNow - 120, 0, 0, 0, 1),
            (3, 3, 2, epochNow - 180, 0, 0, 0, 1),
            (4, 4, 2, epochNow - 240, 1, 0, 0, 1),
            (5, 5, 2, epochNow - 300, 0, 0, 1, 1),
            (6, 6, 2, epochNow - 360, 0, 1, 0, 1),
            (7, 7, 2, epochNow - 600, 0, 0, 0, 1),
            (8, 8, 2, referenceNow - 900, 0, 0, 0, 1),
            (9, 9, 2, epochNow - 400_000, 0, 0, 0, 1),
            (10, 10, 2, referenceNow - 400_000, 0, 0, 0, 1),
            (11, 11, 2, epochNow - 700, 0, 0, 0, 1),
            (12, 12, 2, epochNow - 800, 0, 0, 0, 3)
        ]
        for (id, subject, sender, date, read, deleted, junk, mailbox) in rows {
            try execute(
                """
                INSERT INTO messages
                    (ROWID, message_id, subject, sender, date_received, read, deleted, junk, mailbox)
                VALUES (\(id), 'm\(id)', \(subject), \(sender), \(date), \(read), \(deleted), \(junk), \(mailbox));
                """,
                on: database
            )
        }
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw error(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "MailProviderSearchSemanticsTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
