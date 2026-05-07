import AppKit
import EventKit
import Foundation
import M3MCPCore

final class CalendarProvider {
    private let store = EKEventStore()

    func search(input: [String: JSONValue]) async -> ToolResponse {
        do {
            let granted = try await requestAccess()
            guard granted else {
                return ToolResponse(ok: false, source: "EventKit", message: "Calendar access was not granted.")
            }

            let query = StringSanitizer.lower(input.string("query"))
            let limit = max(1, min(input.int("limit", default: 25), 100))
            let startDays = input.int("start_days", default: -7)
            let endDays = input.int("end_days", default: 60)
            let start = Calendar.current.date(byAdding: .day, value: startDays, to: Date()) ?? Date()
            let end = Calendar.current.date(byAdding: .day, value: endDays, to: Date()) ?? Date().addingTimeInterval(60 * 60 * 24 * 60)

            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: predicate)
                .filter { event in
                    guard !query.isEmpty else { return true }
                    let haystack = [
                        event.title,
                        event.location,
                        event.notes,
                        event.calendar.title
                    ]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .localizedLowercase
                    return haystack.contains(query)
                }
                .sorted { $0.startDate < $1.startDate }
                .prefix(limit)

            let formatter = ISO8601DateFormatter()
            let items = events.map { event in
                DataItem(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "(untitled event)",
                    subtitle: event.location,
                    kind: "calendar_event",
                    source: "EventKit",
                    preview: StringSanitizer.compact(event.notes ?? "", limit: 900),
                    metadata: {
                        var m: [String: String] = [
                            "calendar": event.calendar.title,
                            "start": formatter.string(from: event.startDate),
                            "end": formatter.string(from: event.endDate),
                            "all_day": String(event.isAllDay)
                        ]
                        if let url = event.url?.absoluteString {
                            m["url"] = url
                        }
                        return m
                    }()
                )
            }

            return ToolResponse(ok: true, source: "EventKit", items: Array(items))
        } catch {
            return ToolResponse(ok: false, source: "EventKit", message: error.localizedDescription)
        }
    }

    @MainActor
    private func requestAccess() async throws -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
        return granted
    }
}
