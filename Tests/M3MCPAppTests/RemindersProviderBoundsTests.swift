import EventKit
import M3MCPCore
import XCTest
@testable import M3MCPApp

final class RemindersProviderBoundsTests: XCTestCase {
    func testContradictoryCompletionFiltersFailBeforeAuthorizationBoundary() async {
        let response = await RemindersProvider().search(input: [
            "completed_only": .bool(true),
            "incomplete_only": .bool(true)
        ])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("cannot both be true") == true)
    }

    func testOversizedQueryFailsBeforeAuthorizationBoundary() async {
        let response = await RemindersProvider().search(input: [
            "query": .string(String(repeating: "q", count: RemindersProvider.maximumQueryUTF8Bytes + 1))
        ])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("work limit") == true)
    }

    func testPostFetchCandidateBudgetHasSafeDefaultAndAbsoluteMaximum() {
        XCTAssertEqual(RemindersProvider.candidateLimit(input: [:]), 1_000)
        XCTAssertEqual(
            RemindersProvider.candidateLimit(input: ["max_candidates": .number(99_999)]),
            RemindersProvider.maximumCandidates
        )
        XCTAssertEqual(RemindersProvider.candidateLimit(input: ["max_candidates": .number(-1)]), 1)
    }

    func testReminderFieldsAreBoundedBelowTransportCeiling() throws {
        let store = EKEventStore()
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        let hostile = String(repeating: "\u{0001}", count: 100_000)
        calendar.title = hostile

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = hostile
        reminder.notes = hostile

        let item = RemindersProvider.makeItem(
            reminder,
            metadata: ["completed": "false", "priority": "0"]
        )
        let encoded = try M3JSON.makeEncoder().encode(
            ToolResponse(ok: true, source: "Reminders", items: Array(repeating: item, count: 100))
        )

        XCTAssertEqual(item.metadata["content_truncated"], "true")
        XCTAssertLessThanOrEqual(item.title.utf8.count, RemindersProvider.maximumTitleUTF8Bytes)
        XCTAssertLessThanOrEqual(
            item.preview?.utf8.count ?? .max,
            RemindersProvider.maximumNotesPreviewUTF8Bytes
        )
        XCTAssertLessThan(encoded.count, LocalHTTPResponseParser.maximumBodyBytes)
    }
}
