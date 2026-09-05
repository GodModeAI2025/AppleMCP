import EventKit
import Foundation
import M3MCPCore
import XCTest
@testable import M3MCPApp

/// The undo contract measured on real `EKEvent` objects.
///
/// These are EventKit's own types, built in memory and never handed to a store, so the mapping under
/// test is the one the app actually runs. What they cannot cover is the commit: saving, removing,
/// and reading back require Calendar authorization. `CalendarUndoLiveTests` covers that half on a
/// machine that has it.
final class CalendarUndoSnapshotTests: XCTestCase {
    private let store = EKEventStore()

    private func makeEvent(
        title: String = "Weekly review",
        allDay: Bool = false
    ) -> EKEvent {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Work"

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.isAllDay = allDay
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = Date(timeIntervalSince1970: 1_800_003_600)
        event.location = "Room 3"
        event.notes = "Project: apple-mcp\nBring the numbers"
        event.url = URL(string: "https://example.invalid/review")
        event.addAlarm(EKAlarm(relativeOffset: -600))
        return event
    }

    func testSnapshotCapturesEveryFieldTheWriteToolsCanSet() {
        let provider = CalendarProvider()
        let event = makeEvent()

        let snapshot = provider.snapshot(of: event)

        XCTAssertEqual(snapshot.title, "Weekly review")
        XCTAssertFalse(snapshot.isAllDay)
        XCTAssertEqual(snapshot.startDate, event.startDate)
        XCTAssertEqual(snapshot.endDate, event.endDate)
        XCTAssertEqual(snapshot.location, "Room 3")
        XCTAssertEqual(snapshot.notes, "Project: apple-mcp\nBring the numbers")
        XCTAssertEqual(snapshot.url, "https://example.invalid/review")
        XCTAssertEqual(snapshot.calendarIdentifier, event.calendar.calendarIdentifier)
        XCTAssertEqual(snapshot.alarmOffsetsSeconds, [-600])
    }

    func testAnAbsoluteAlarmIsNotRecordedAsARelativeOne() {
        let provider = CalendarProvider()
        let event = makeEvent()
        event.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_799_000_000)))

        // The write tools only ever create relative alarms, so restoring an absolute one as a
        // relative offset would invent a reminder the calendar never had.
        XCTAssertEqual(provider.snapshot(of: event).alarmOffsetsSeconds, [-600])
    }

    func testAnUpdateIsReversedFieldByFieldAndLeavesUntouchedFieldsAlone() {
        let provider = CalendarProvider()
        let event = makeEvent()
        let before = provider.snapshot(of: event)
        let untouchedNotes = event.notes
        let untouchedAlarms = event.alarms?.count

        // What calendar_update_event would do for {title, location, url}.
        event.title = "Weekly review (moved)"
        event.location = "Room 9"
        event.url = URL(string: "https://example.invalid/moved")

        let previous = CalendarProvider.previousValues(
            from: before,
            changedFieldNames: ["title", "location", "url"]
        )
        XCTAssertEqual(Set(previous.keys), [.title, .location, .url])

        guard case .success(let restored) = provider.applyPreviousValues(previous, to: event) else {
            return XCTFail("restoring recorded values must succeed")
        }

        XCTAssertEqual(restored, ["location", "title", "url"])
        XCTAssertEqual(event.title, "Weekly review")
        XCTAssertEqual(event.location, "Room 3")
        XCTAssertEqual(event.url?.absoluteString, "https://example.invalid/review")
        XCTAssertEqual(event.notes, untouchedNotes)
        XCTAssertEqual(event.alarms?.count, untouchedAlarms)
    }

    func testAFieldThatHadNoValueIsRestoredToHavingNone() {
        let provider = CalendarProvider()
        let event = makeEvent()
        event.location = nil
        event.url = nil
        let before = provider.snapshot(of: event)

        event.location = "Room 9"
        event.url = URL(string: "https://example.invalid/added")

        let previous = CalendarProvider.previousValues(
            from: before,
            changedFieldNames: ["location", "url"]
        )
        XCTAssertEqual(previous[.location], .cleared)
        XCTAssertEqual(previous[.url], .cleared)

        guard case .success = provider.applyPreviousValues(previous, to: event) else {
            return XCTFail("restoring an absent value must succeed")
        }
        // The distinction the record keeps: "there was no location" is not "location was not
        // touched". Collapsing them would leave the added value in place and call it an undo.
        XCTAssertNil(event.location)
        XCTAssertNil(event.url)
    }

    func testTogglingAllDayAlsoRecordsTheTimesItDrags() {
        let before = M3MCPCalendarEventSnapshot(
            title: "Weekly review",
            isAllDay: false,
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_003_600),
            calendarIdentifier: "calendar-1"
        )

        let previous = CalendarProvider.previousValues(
            from: before,
            changedFieldNames: ["all_day"]
        )

        // The caller passed all_day alone. EventKit normalizes the times with it, so restoring the
        // flag on its own would leave the normalized times behind.
        XCTAssertEqual(Set(previous.keys), [.allDay, .start, .end])
        XCTAssertEqual(previous[.allDay], .flag(false))
        XCTAssertEqual(previous[.start], .timestamp(Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(previous[.end], .timestamp(Date(timeIntervalSince1970: 1_800_003_600)))
    }

    func testNotesAndProjectSlugAreOneFieldInTheRecord() {
        let before = M3MCPCalendarEventSnapshot(
            title: "Weekly review",
            notes: "Project: apple-mcp\nBring the numbers",
            calendarIdentifier: "calendar-1"
        )

        for name in ["notes", "project_slug"] {
            let previous = CalendarProvider.previousValues(from: before, changedFieldNames: [name])
            XCTAssertEqual(Set(previous.keys), [.notes], name)
            XCTAssertEqual(previous[.notes], .text("Project: apple-mcp\nBring the numbers"), name)
        }

        // Both at once still records the one field they share, and records it once.
        let both = CalendarProvider.previousValues(
            from: before,
            changedFieldNames: ["notes", "project_slug"]
        )
        XCTAssertEqual(Set(both.keys), [.notes])
    }

    func testRestoringRefusesToLeaveTheEventEndingBeforeItStarts() {
        let provider = CalendarProvider()
        let event = makeEvent()

        let corrupted: [M3MCPCalendarField: M3MCPCalendarPreviousValue] = [
            .start: .timestamp(Date(timeIntervalSince1970: 1_800_009_000)),
            .end: .timestamp(Date(timeIntervalSince1970: 1_800_000_000))
        ]

        guard case .failure(let problem) = provider.applyPreviousValues(corrupted, to: event) else {
            return XCTFail("an impossible restore must be refused, not saved")
        }
        XCTAssertTrue(problem.message.contains("before 'start'"))
    }

    func testRebuildingADeletedEventNeedsACalendarThatStillExists() {
        let provider = CalendarProvider()
        let event = makeEvent()
        let snapshot = provider.snapshot(of: event)

        // The snapshot names a calendar this store cannot resolve, which is exactly the state after
        // the calendar itself was removed. A rebuild must say so rather than pick a default.
        guard case .failure(let problem) = provider.rebuild(from: snapshot) else {
            return XCTFail("a rebuild into a vanished calendar must be refused")
        }
        XCTAssertTrue(problem.message.contains("no longer exists"))
    }

    func testRebuildingRefusesASnapshotWithoutTimes() {
        let provider = CalendarProvider()
        let snapshot = M3MCPCalendarEventSnapshot(
            title: "Weekly review",
            calendarIdentifier: "calendar-1"
        )

        guard case .failure(let problem) = provider.rebuild(from: snapshot) else {
            return XCTFail("a snapshot without times cannot rebuild an event")
        }
        XCTAssertTrue(problem.message.contains("no start or end"))
    }

    func testAnUndoTokenIsWithheldForRecurringSeriesAndForFutureOccurrences() {
        let event = makeEvent()

        XCTAssertTrue(CalendarProvider.undoIsRepresentable(event: event, span: .thisEvent))
        XCTAssertNil(CalendarProvider.undoUnavailableReason(event: event, span: .thisEvent))

        XCTAssertFalse(CalendarProvider.undoIsRepresentable(event: event, span: .futureEvents))
        XCTAssertEqual(
            CalendarProvider.undoUnavailableReason(event: event, span: .futureEvents),
            "no undo snapshot: span 'future_events' changes occurrences a single snapshot cannot describe"
        )

        event.recurrenceRules = [
            EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        ]
        XCTAssertFalse(CalendarProvider.undoIsRepresentable(event: event, span: .thisEvent))
        XCTAssertEqual(
            CalendarProvider.undoUnavailableReason(event: event, span: .thisEvent),
            "no undo snapshot: the event is part of a recurring series"
        )
    }

    func testTheSummaryOnTheApprovalSheetIsBoundedByAHostileTitle() {
        let hostile = String(repeating: "T", count: 10_000)
        let summary = CalendarProvider.undoSummary("deleting '\(hostile)'")

        XCTAssertLessThanOrEqual(
            summary.utf8.count,
            CalendarProvider.maximumUndoSummaryUTF8Bytes
        )
    }
}
