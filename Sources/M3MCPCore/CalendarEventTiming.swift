import Foundation

public enum CalendarEventTiming {
    /// Resolves an event end without creating a zero-duration all-day event. Calendar arithmetic is
    /// used for the default all-day duration so daylight-saving transitions remain one local day.
    public static func resolvedEnd(
        start: Date,
        explicitEnd: Date?,
        durationMinutes: Int?,
        isAllDay: Bool,
        calendar: Calendar = .current
    ) -> Date? {
        if let explicitEnd {
            return explicitEnd
        }
        if let durationMinutes, durationMinutes > 0 {
            return start.addingTimeInterval(TimeInterval(durationMinutes) * 60)
        }
        if isAllDay {
            return calendar.date(byAdding: .day, value: 1, to: start)
        }
        return nil
    }

    public static func isValid(start: Date, end: Date) -> Bool {
        end > start
    }
}
