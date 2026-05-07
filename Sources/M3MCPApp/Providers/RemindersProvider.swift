import AppKit
import EventKit
import Foundation
import M3MCPCore

final class RemindersProvider {
    private let store = EKEventStore()

    func search(input: [String: JSONValue]) async -> ToolResponse {
        do {
            let granted = try await requestAccess()
            guard granted else {
                return ToolResponse(ok: false, source: "Reminders", message: "Reminders access was not granted.")
            }

            let query = StringSanitizer.lower(input.string("query"))
            let limit = max(1, min(input.int("limit", default: 25), 100))
            let completedOnly = input.bool("completed_only", default: false)
            let incompleteOnly = input.bool("incomplete_only", default: false)

            let lists = store.calendars(for: .reminder)
            let predicate: NSPredicate
            if completedOnly {
                predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: lists)
            } else if incompleteOnly {
                predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
            } else {
                predicate = store.predicateForReminders(in: lists)
            }

            let reminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
                store.fetchReminders(matching: predicate) { result in
                    continuation.resume(returning: result ?? [])
                }
            }

            let formatter = ISO8601DateFormatter()
            let filtered = reminders
                .filter { reminder in
                    guard !query.isEmpty else { return true }
                    let haystack = [reminder.title, reminder.notes, reminder.calendar.title]
                        .compactMap { $0 }
                        .joined(separator: " ")
                        .localizedLowercase
                    return haystack.contains(query)
                }
                .sorted {
                    let a = $0.dueDateComponents?.date ?? Date.distantFuture
                    let b = $1.dueDateComponents?.date ?? Date.distantFuture
                    return a < b
                }
                .prefix(limit)

            let items = filtered.map { reminder in
                var meta: [String: String] = [
                    "list": reminder.calendar.title,
                    "completed": String(reminder.isCompleted),
                    "priority": String(reminder.priority)
                ]
                if let dueDate = reminder.dueDateComponents?.date {
                    meta["due"] = formatter.string(from: dueDate)
                }
                if let completed = reminder.completionDate {
                    meta["completed_at"] = formatter.string(from: completed)
                }

                return DataItem(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "(untitled reminder)",
                    subtitle: reminder.calendar.title,
                    kind: "reminder",
                    source: "Reminders",
                    preview: reminder.notes.flatMap { StringSanitizer.compact($0, limit: 400) },
                    metadata: meta
                )
            }

            return ToolResponse(ok: true, source: "Reminders", items: Array(items))
        } catch {
            return ToolResponse(ok: false, source: "Reminders", message: error.localizedDescription)
        }
    }

    @MainActor
    private func requestAccess() async throws -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            store.requestFullAccessToReminders { granted, error in
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
