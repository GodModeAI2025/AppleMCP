import Darwin
import Foundation
import M3MCPCore
import SQLite3
import XCTest
@testable import M3MCPApp

final class MailProviderCancellationTests: XCTestCase {
    func testPrecancelledToolsReturnStableCancellationResponsesWithoutReadingMail() async {
        let provider = MailProvider()

        let search = await inPrecancelledTask {
            await provider.search(input: [:])
        }
        let mailboxes = await inPrecancelledTask {
            await provider.listMailboxes(input: [:])
        }
        let read = await inPrecancelledTask {
            await provider.read(input: ["id": .string("1")])
        }

        for response in [search, mailboxes, read] {
            assertCancellation(response)
        }
    }

    func testCancellationStopsDatabaseBodyAndFallbackFileScans() async throws {
        let fixture = try makeFixture(messageCount: 500)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await withMailRoot(fixture.root) {
            let databaseRows = await cancelAt(.messageRow) { provider in
                await provider.search(input: [
                    "query": .string(""),
                    "limit": .number(500),
                    "auto_intent": .bool(false)
                ])
            }
            assertCancellation(databaseRows)

            let sqliteVirtualMachine = await cancelAt(.sqliteProgress) { provider in
                await provider.search(input: [
                    "query": .string("not-present"),
                    "fields": .array([.string("subject")]),
                    "limit": .number(500),
                    "auto_intent": .bool(false)
                ])
            }
            assertCancellation(sqliteVirtualMachine)

            let bodyParsing = await cancelAt(.bodyParsing) { provider in
                await provider.search(input: [
                    "query": .string("bodyneedle"),
                    "fields": .array([.string("body")]),
                    "limit": .number(10),
                    "max_candidates": .number(500),
                    "auto_intent": .bool(false)
                ])
            }
            assertCancellation(bodyParsing)

            // Message 2 deliberately has no direct .emlx file. mail_read therefore enters the
            // bounded 50,000-entry fallback enumerator, where cancellation must win as well.
            let fallbackFileSearch = await cancelAt(.emlxSearchEntry) { provider in
                await provider.read(input: ["id": .string("2")])
            }
            assertCancellation(fallbackFileSearch)
        }
    }

    private func cancelAt(
        _ checkpoint: MailProvider.CancellationCheckpoint,
        operation: @escaping (MailProvider) async -> ToolResponse
    ) async -> ToolResponse {
        let gate = BlockingCancellationGate(checkpoint: checkpoint)
        let provider = MailProvider(cancellationCheck: gate.check)
        let task = Task {
            await operation(provider)
        }

        let reached = gate.waitUntilReached(timeout: 3)
        task.cancel()
        gate.release()
        XCTAssertTrue(reached, "Mail request never reached cancellation checkpoint \(checkpoint)")
        return await task.value
    }

    private func inPrecancelledTask(
        _ operation: @escaping () async -> ToolResponse
    ) async -> ToolResponse {
        await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await operation()
        }.value
    }

    private func assertCancellation(
        _ response: ToolResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(response.ok, file: file, line: line)
        XCTAssertEqual(response.source, "Mail Local Index", file: file, line: line)
        XCTAssertEqual(response.message, "Mail request was cancelled.", file: file, line: line)
        XCTAssertTrue(response.items.isEmpty, file: file, line: line)
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

    private func makeFixture(messageCount: Int) throws -> (root: URL, index: URL) {
        let root = URL(
            fileURLWithPath: "/private/tmp/m3mail-cancellation-\(UUID().uuidString)",
            isDirectory: true
        )
        let mailData = root.appendingPathComponent("V10/MailData", isDirectory: true)
        let messages = root.appendingPathComponent("V10/Mailboxes/Inbox/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)

        let index = mailData.appendingPathComponent("Envelope Index")
        var database: OpaquePointer?
        guard sqlite3_open(index.path, &database) == SQLITE_OK, let database else {
            throw fixtureError("could not create synthetic Envelope Index")
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE mailboxes (url TEXT, total_count INTEGER, unread_count INTEGER);
            INSERT INTO mailboxes (ROWID, url, total_count, unread_count)
            VALUES (1, 'Mailboxes/Inbox', \(messageCount), \(messageCount));

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

            WITH RECURSIVE sequence(id) AS (
                VALUES(1)
                UNION ALL
                SELECT id + 1 FROM sequence WHERE id < \(messageCount)
            )
            INSERT INTO messages
                (ROWID, message_id, subject, sender, date_received, read, deleted, junk, mailbox)
            SELECT id, CAST(id AS TEXT), 'subject ' || id, 'sender@example.test',
                   2000000000 - id, 0, 0, 0, 1
            FROM sequence;
            """,
            on: database
        )

        let email = """
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        To: recipient@example.test\r
        \r
        bodyneedle=20appears=20in=20this=20message\r
        """
        let emlx = "\(email.utf8.count)\n\(email)"
        try Data(emlx.utf8).write(to: messages.appendingPathComponent("1.emlx"))

        return (root, index)
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw fixtureError(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(
            domain: "MailProviderCancellationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private final class BlockingCancellationGate {
    private let checkpoint: MailProvider.CancellationCheckpoint
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var didBlock = false

    init(checkpoint: MailProvider.CancellationCheckpoint) {
        self.checkpoint = checkpoint
    }

    func check(_ current: MailProvider.CancellationCheckpoint) -> Bool {
        guard current == checkpoint else { return Task.isCancelled }

        lock.lock()
        let shouldBlock = !didBlock
        didBlock = true
        lock.unlock()

        if shouldBlock {
            reached.signal()
            resume.wait()
        }
        return Task.isCancelled
    }

    func waitUntilReached(timeout: TimeInterval) -> Bool {
        reached.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        resume.signal()
    }
}
