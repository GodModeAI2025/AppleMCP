import Foundation
import XCTest
@testable import M3MCPCore

final class CalendarEventTimingTests: XCTestCase {
    func testAllDayDefaultEndsAtNextLocalDayAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 29, hour: 0
        )))

        let end = try XCTUnwrap(CalendarEventTiming.resolvedEnd(
            start: start,
            explicitEnd: nil,
            durationMinutes: nil,
            isAllDay: true,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: end), DateComponents(
            year: 2026, month: 3, day: 30, hour: 0
        ))
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 60 * 60)
    }

    func testExplicitEndAndDurationTakePrecedence() {
        let start = Date(timeIntervalSince1970: 1_000)
        let explicit = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(CalendarEventTiming.resolvedEnd(
            start: start,
            explicitEnd: explicit,
            durationMinutes: 10,
            isAllDay: true
        ), explicit)
        XCTAssertEqual(CalendarEventTiming.resolvedEnd(
            start: start,
            explicitEnd: nil,
            durationMinutes: 10,
            isAllDay: false
        ), Date(timeIntervalSince1970: 1_600))
    }

    func testTimedEventNeedsEndAndIntervalsMustBePositive() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(CalendarEventTiming.resolvedEnd(
            start: start,
            explicitEnd: nil,
            durationMinutes: nil,
            isAllDay: false
        ))
        XCTAssertFalse(CalendarEventTiming.isValid(start: start, end: start))
        XCTAssertFalse(CalendarEventTiming.isValid(start: start, end: start.addingTimeInterval(-1)))
        XCTAssertTrue(CalendarEventTiming.isValid(start: start, end: start.addingTimeInterval(1)))
    }
}
