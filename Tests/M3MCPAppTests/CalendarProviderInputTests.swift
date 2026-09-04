import Foundation
import EventKit
import M3MCPCore
import XCTest
@testable import M3MCPApp

final class CalendarProviderInputTests: XCTestCase {
    func testExplicitEndCannotSilentlyFallBackWhenPresentButMalformed() {
        let provider = CalendarProvider()

        XCTAssertEqual(provider.explicitEndValue(from: nil, allDay: false), .omitted)
        XCTAssertEqual(provider.explicitEndValue(from: "", allDay: false), .invalid)
        XCTAssertEqual(provider.explicitEndValue(from: "not-a-date", allDay: false), .invalid)

        switch provider.explicitEndValue(from: "2026-09-05T12:00:00+02:00", allDay: false) {
        case .parsed:
            break
        case .omitted, .invalid:
            XCTFail("valid explicit end was not parsed")
        }

        switch provider.explicitEndValue(from: "2026-09-05", allDay: true) {
        case .parsed:
            break
        case .omitted, .invalid:
            XCTFail("valid all-day end was not parsed")
        }
    }

    func testSearchCandidateBudgetHasSafeDefaultAndAbsoluteMaximum() {
        XCTAssertEqual(CalendarProvider.searchCandidateLimit(input: [:]), 2_000)
        XCTAssertEqual(
            CalendarProvider.searchCandidateLimit(input: ["max_candidates": .number(99_999)]),
            CalendarProvider.maximumSearchCandidates
        )
        XCTAssertEqual(
            CalendarProvider.searchCandidateLimit(input: ["max_candidates": .number(-1)]),
            1
        )
    }

    func testOversizedQueryFailsBeforeCalendarAuthorizationBoundary() async {
        let response = await CalendarProvider().search(input: [
            "query": .string(String(repeating: "q", count: CalendarProvider.maximumQueryUTF8Bytes + 1))
        ])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("work limit") == true)
    }

    func testEventFieldsAreBoundedBelowTransportCeiling() throws {
        let store = EKEventStore()
        let calendar = EKCalendar(for: .event, eventStore: store)
        let hostile = String(repeating: "\u{0001}", count: 100_000)
        calendar.title = hostile

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = hostile
        event.location = hostile
        event.notes = hostile
        event.url = URL(string: "https://example.invalid/" + String(repeating: "a", count: 8_000))
        event.startDate = Date()
        event.endDate = event.startDate.addingTimeInterval(60)

        let item = CalendarProvider().item(for: event)
        let encoded = try M3JSON.makeEncoder().encode(
            ToolResponse(ok: true, source: "EventKit", items: Array(repeating: item, count: 100))
        )

        XCTAssertEqual(item.metadata["content_truncated"], "true")
        XCTAssertLessThanOrEqual(item.title.utf8.count, CalendarProvider.maximumTitleUTF8Bytes)
        XCTAssertLessThanOrEqual(item.preview?.utf8.count ?? .max, CalendarProvider.maximumPreviewUTF8Bytes)
        XCTAssertLessThan(encoded.count, LocalHTTPResponseParser.maximumBodyBytes)
    }
}
