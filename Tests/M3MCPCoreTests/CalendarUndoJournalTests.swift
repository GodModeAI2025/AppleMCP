import XCTest
@testable import M3MCPCore

/// The journal decides how long a mistake stays correctable and how often it may be corrected.
/// Both bounds are enforced here with an injected clock, so neither depends on wall time.
final class CalendarUndoJournalTests: XCTestCase {
    private func fixedSnapshot(title: String) -> M3MCPCalendarEventSnapshot {
        M3MCPCalendarEventSnapshot(
            title: title,
            isAllDay: false,
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 4_600),
            calendarIdentifier: "calendar-1"
        )
    }

    func testATokenIsSpentOnceAndTheSecondCallSaysWhy() async {
        let tokens = TokenSequence()
        let journal = M3MCPCalendarUndoJournal(makeToken: { tokens.next() })

        let record = await journal.record(
            tool: .calendarDeleteEvent,
            summary: "deleting 'Standup'",
            action: .recreateDeletedEvent(fixedSnapshot(title: "Standup"))
        )
        XCTAssertEqual(record.token, "token-1")

        let first = await journal.consume(token: "token-1")
        guard case .found(let found) = first else {
            return XCTFail("the first undo must find its snapshot")
        }
        XCTAssertEqual(found.summary, "deleting 'Standup'")

        // A replayed undo must not act a second time. Told apart from a wrong token, because the
        // caller can do something about one and not the other.
        let second = await journal.consume(token: "token-1")
        XCTAssertEqual(second, .alreadyUndone)
        let peeked = await journal.peek(token: "token-1")
        XCTAssertEqual(peeked, .alreadyUndone)
        let unissued = await journal.consume(token: "never-issued")
        XCTAssertEqual(unissued, .unknown)
        let remaining = await journal.count
        XCTAssertEqual(remaining, 0)
    }

    func testPeekReadsThePlanWithoutSpendingIt() async {
        let journal = M3MCPCalendarUndoJournal(makeToken: { "token-peek" })
        await journal.record(
            tool: .calendarCreateEvent,
            summary: "creating 'Retro'",
            action: .removeCreatedEvent(eventIdentifier: "event-1")
        )

        for _ in 0..<3 {
            guard case .found = await journal.peek(token: "token-peek") else {
                return XCTFail("peek must not consume the token it reads")
            }
        }
        guard case .found = await journal.consume(token: "token-peek") else {
            return XCTFail("the token must still be spendable after being previewed")
        }
    }

    func testAnExpiredTokenIsReportedAsExpiredAndNotAsUnknown() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let journal = M3MCPCalendarUndoJournal(
            lifetime: 60,
            now: { clock.now },
            makeToken: { "token-ttl" }
        )
        await journal.record(
            tool: .calendarUpdateEvent,
            summary: "updating title on 'Retro'",
            action: .restorePreviousValues(
                eventIdentifier: "event-1",
                previous: [.title: .text("Retro")]
            )
        )

        clock.advance(59)
        guard case .found = await journal.peek(token: "token-ttl") else {
            return XCTFail("a token inside its lifetime must resolve")
        }

        clock.advance(2)
        let expiredPeek = await journal.peek(token: "token-ttl")
        XCTAssertEqual(expiredPeek, .expired)
        let expiredConsume = await journal.consume(token: "token-ttl")
        XCTAssertEqual(expiredConsume, .expired)
        let remaining = await journal.count
        XCTAssertEqual(remaining, 0)
    }

    func testTheOldestRecordIsEvictedOnceCapacityIsReached() async {
        let tokens = TokenSequence()
        let journal = M3MCPCalendarUndoJournal(capacity: 3, makeToken: { tokens.next() })

        for index in 1...5 {
            await journal.record(
                tool: .calendarCreateEvent,
                summary: "creating 'Event \(index)'",
                action: .removeCreatedEvent(eventIdentifier: "event-\(index)")
            )
        }

        let held = await journal.count
        XCTAssertEqual(held, 3)
        // Evicted, not expired and not spent: the caller is told the token is unknown rather than
        // being led to believe an undo is still waiting.
        let evictedFirst = await journal.peek(token: "token-1")
        XCTAssertEqual(evictedFirst, .unknown)
        let evictedSecond = await journal.peek(token: "token-2")
        XCTAssertEqual(evictedSecond, .unknown)
        guard case .found = await journal.peek(token: "token-3") else {
            return XCTFail("the three most recent writes must stay correctable")
        }
        guard case .found = await journal.peek(token: "token-5") else {
            return XCTFail("the newest write must stay correctable")
        }
    }

    func testAFailedUndoGetsItsTokenBackButAnExpiredOneDoesNot() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let tokens = TokenSequence()
        let journal = M3MCPCalendarUndoJournal(
            lifetime: 60,
            now: { clock.now },
            makeToken: { tokens.next() }
        )

        let record = await journal.record(
            tool: .calendarDeleteEvent,
            summary: "deleting 'Standup'",
            action: .recreateDeletedEvent(fixedSnapshot(title: "Standup"))
        )
        guard case .found(let taken) = await journal.consume(token: record.token) else {
            return XCTFail("the token must be spendable")
        }

        await journal.reinstate(taken)
        guard case .found = await journal.peek(token: record.token) else {
            return XCTFail("an undo that changed nothing must leave its token usable")
        }

        // Reinstating twice must not duplicate the record.
        await journal.reinstate(taken)
        let held = await journal.count
        XCTAssertEqual(held, 1)

        // And putting one back cannot extend a lifetime that has already run out: the record does
        // not return to the journal, and the token keeps reporting that it was spent.
        guard case .found(let again) = await journal.consume(token: record.token) else {
            return XCTFail("the reinstated token must be spendable")
        }
        clock.advance(61)
        await journal.reinstate(again)
        let afterLifetime = await journal.count
        XCTAssertEqual(afterLifetime, 0)
        let lookup = await journal.peek(token: record.token)
        XCTAssertEqual(lookup, .alreadyUndone)
    }

    func testTheRecordSaysWhenAnIdentifierCannotComeBack() {
        let recreate = M3MCPCalendarUndoRecord(
            token: "t",
            tool: .calendarDeleteEvent,
            summary: "deleting 'Standup'",
            action: .recreateDeletedEvent(fixedSnapshot(title: "Standup")),
            recordedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 60)
        )
        XCTAssertFalse(recreate.restoresIdentifier)

        let restore = M3MCPCalendarUndoRecord(
            token: "t",
            tool: .calendarUpdateEvent,
            summary: "updating title on 'Standup'",
            action: .restorePreviousValues(
                eventIdentifier: "event-1",
                previous: [.title: .cleared]
            ),
            recordedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 60)
        )
        XCTAssertTrue(restore.restoresIdentifier)
    }
}

/// A clock the test moves by hand. `Date()` would make the lifetime assertions a bet on how fast the
/// machine runs them.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Predictable token names, so an assertion can name the record it means.
private final class TokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        issued += 1
        return "token-\(issued)"
    }
}
