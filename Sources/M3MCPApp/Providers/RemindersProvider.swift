import EventKit
import Foundation
import M3MCPCore

final class RemindersProvider {
    static let maximumQueryUTF8Bytes = 4_096
    static let defaultMaximumCandidates = 1_000
    static let maximumCandidates = 5_000
    static let maximumTitleUTF8Bytes = 1_024
    static let maximumListTitleUTF8Bytes = 512
    static let maximumNotesPreviewUTF8Bytes = 2_048
    static let maximumSearchFieldUTF8Bytes = 16 * 1_024

    private let store = EKEventStore()

    func search(input: [String: JSONValue]) async -> ToolResponse {
        do {
            guard !Task.isCancelled else {
                return cancellationResponse()
            }

            let rawQuery = input.string("query")
            guard rawQuery.utf8.count <= Self.maximumQueryUTF8Bytes else {
                return ToolResponse(
                    ok: false,
                    source: "Reminders",
                    message: "Reminders query exceeds the \(Self.maximumQueryUTF8Bytes)-byte work limit."
                )
            }
            let completedOnly = input.bool("completed_only", default: false)
            let incompleteOnly = input.bool("incomplete_only", default: false)
            guard !(completedOnly && incompleteOnly) else {
                return ToolResponse(
                    ok: false,
                    source: "Reminders",
                    message: "completed_only and incomplete_only cannot both be true."
                )
            }

            guard hasReadAccess else {
                return ToolResponse(
                    ok: false,
                    source: "Reminders",
                    message: "Reminders access is not authorized. Grant it in System Settings, or explicitly enable and call permissions_request."
                )
            }

            let query = StringSanitizer.lower(rawQuery)
            let limit = max(1, min(input.int("limit", default: 25), 100))
            let maxCandidates = Self.candidateLimit(input: input)

            let lists = store.calendars(for: .reminder)
            var reminders: [EKReminder] = []
            reminders.reserveCapacity(maxCandidates)
            var frameworkReturned = 0
            var listsFetched = 0
            var fetchScopeCapped = false

            // EventKit has no fetch-limit parameter and materializes each callback result. Fetch one
            // list at a time so reaching the provider's post-fetch budget avoids asking later lists,
            // while honestly reporting that one very large list can still be materialized by EventKit.
            for (index, list) in lists.enumerated() {
                guard !Task.isCancelled else { return cancellationResponse() }
                let predicate: NSPredicate
                if completedOnly {
                    predicate = store.predicateForCompletedReminders(
                        withCompletionDateStarting: nil,
                        ending: nil,
                        calendars: [list]
                    )
                } else if incompleteOnly {
                    predicate = store.predicateForIncompleteReminders(
                        withDueDateStarting: nil,
                        ending: nil,
                        calendars: [list]
                    )
                } else {
                    predicate = store.predicateForReminders(in: [list])
                }

                let listReminders = try await fetchReminders(matching: predicate)
                listsFetched += 1
                let addition = frameworkReturned.addingReportingOverflow(listReminders.count)
                frameworkReturned = addition.overflow ? Int.max : addition.partialValue
                let remaining = maxCandidates - reminders.count
                reminders.append(contentsOf: listReminders.prefix(max(0, remaining)))
                if listReminders.count > remaining || (reminders.count >= maxCandidates && index + 1 < lists.count) {
                    fetchScopeCapped = true
                    break
                }
            }

            guard !Task.isCancelled else { return cancellationResponse() }

            let formatter = ISO8601DateFormatter()
            let inspectedCount = reminders.count
            var filtered: [EKReminder] = []
            filtered.reserveCapacity(min(inspectedCount, limit + 1))
            var searchContentCapped = false
            for reminder in reminders {
                guard !Task.isCancelled else { return cancellationResponse() }
                if !query.isEmpty {
                    let searchableFields = [reminder.title, reminder.notes, reminder.calendar.title]
                        .compactMap { $0 }
                        .map {
                            ProviderOutputBudget.text(
                                $0,
                                maximumUTF8Bytes: Self.maximumSearchFieldUTF8Bytes
                            )
                        }
                    searchContentCapped = searchContentCapped
                        || searchableFields.contains(where: \.truncated)
                    let haystack = searchableFields
                        .map(\.text)
                        .joined(separator: " ")
                        .localizedLowercase
                    guard haystack.contains(query) else { continue }
                }
                filtered.append(reminder)
            }
            filtered.sort {
                let a = $0.dueDateComponents?.date ?? Date.distantFuture
                let b = $1.dueDateComponents?.date ?? Date.distantFuture
                return a < b
            }

            let selected = Array(filtered.prefix(limit))
            let items = selected.map { reminder in
                var meta: [String: String] = [
                    "list": "",
                    "completed": String(reminder.isCompleted),
                    "priority": String(reminder.priority)
                ]
                if let dueDate = reminder.dueDateComponents?.date {
                    meta["due"] = formatter.string(from: dueDate)
                }
                if let completed = reminder.completionDate {
                    meta["completed_at"] = formatter.string(from: completed)
                }

                return Self.makeItem(reminder, metadata: meta)
            }

            let hasMore = filtered.count > items.count || fetchScopeCapped
            let message = fetchScopeCapped
                ? "Reminders reached the post-fetch scan budget after \(inspectedCount) items; narrow the query or filters, or raise max_candidates."
                : (searchContentCapped
                    ? "Some reminder fields exceeded the per-field search budget; matches beyond those prefixes were not inspected."
                    : (filtered.count > items.count ? "More reminders matched; increase limit." : nil))
            return ToolResponse(
                ok: true,
                source: "Reminders",
                items: items,
                message: message,
                meta: [
                    "returned": String(items.count),
                    "matching_in_window": String(filtered.count),
                    "inspected": String(inspectedCount),
                    "framework_returned_from_fetched_lists": String(frameworkReturned),
                    "lists_fetched": String(listsFetched),
                    "lists_available": String(lists.count),
                    "post_fetch_scan_budget": String(maxCandidates),
                    "post_fetch_scan_capped": String(fetchScopeCapped),
                    "search_content_capped": String(searchContentCapped),
                    "total_exact": String(!fetchScopeCapped),
                    "has_more": String(hasMore),
                    "truncated": String(hasMore || searchContentCapped)
                ]
            )
        } catch is CancellationError {
            return ToolResponse(ok: false, source: "Reminders", message: "Reminders request was cancelled.")
        } catch {
            return ToolResponse(ok: false, source: "Reminders", message: error.localizedDescription)
        }
    }

    static func candidateLimit(input: [String: JSONValue]) -> Int {
        max(
            1,
            min(input.int("max_candidates", default: defaultMaximumCandidates), maximumCandidates)
        )
    }

    static func makeItem(_ reminder: EKReminder, metadata: [String: String]) -> DataItem {
        let identifier = ProviderOutputBudget.text(
            reminder.calendarItemIdentifier,
            maximumUTF8Bytes: 512
        )
        let title = ProviderOutputBudget.text(
            reminder.title ?? "(untitled reminder)",
            maximumUTF8Bytes: maximumTitleUTF8Bytes
        )
        let list = ProviderOutputBudget.text(
            reminder.calendar.title,
            maximumUTF8Bytes: maximumListTitleUTF8Bytes
        )
        let notesSource = ProviderOutputBudget.text(
            reminder.notes ?? "",
            maximumUTF8Bytes: maximumSearchFieldUTF8Bytes
        )
        // Preserve the existing compact 400-character preview while bounding the source passed to
        // the normalizer and the final UTF-8 representation independently.
        let notes = ProviderOutputBudget.text(
            StringSanitizer.compact(notesSource.text, limit: 400),
            maximumUTF8Bytes: maximumNotesPreviewUTF8Bytes
        )
        var boundedMetadata = metadata
        boundedMetadata["list"] = list.text
        boundedMetadata["content_truncated"] = String(
            identifier.truncated || title.truncated || list.truncated
                || notesSource.truncated || notes.truncated
        )
        return DataItem(
            id: identifier.text,
            title: title.text.isEmpty ? "(untitled reminder)" : title.text,
            subtitle: list.text,
            kind: "reminder",
            source: "Reminders",
            preview: notes.text.isEmpty ? nil : notes.text,
            metadata: boundedMetadata
        )
    }

    private func cancellationResponse() -> ToolResponse {
        ToolResponse(ok: false, source: "Reminders", message: "Reminders request was cancelled.")
    }

    private func fetchReminders(matching predicate: NSPredicate) async throws -> [EKReminder] {
        let cancellationRelay = ReminderFetchCancellationRelay<[EKReminder]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard cancellationRelay.installContinuation(continuation) else {
                    return
                }

                let requestToken = store.fetchReminders(matching: predicate) { result in
                    cancellationRelay.complete(.success(result ?? []))
                }
                cancellationRelay.installRequestCancellation { [store] in
                    store.cancelFetchRequest(requestToken)
                }
            }
        } onCancel: {
            cancellationRelay.cancel()
        }
    }

    private var hasReadAccess: Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return true
        case .writeOnly, .notDetermined, .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }
}

/// Bridges EventKit's callback/token cancellation API into structured concurrency.
///
/// `cancelFetchRequest` deliberately does not invoke EventKit's completion callback. The relay must
/// therefore resume the Swift continuation itself while still remembering cancellation that races
/// before the opaque request token is returned. Callback completion, task cancellation, and a
/// synchronous callback can each win exactly once.
final class ReminderFetchCancellationRelay<Value>: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Value, Error>
    typealias CancelAction = () -> Void

    private enum State {
        case awaitingContinuation
        case awaitingRequest(Continuation)
        case active(Continuation, CancelAction)
        case cancellationPending
        case cancelledAwaitingRequest
        case terminal
    }

    private let lock = NSLock()
    private var state = State.awaitingContinuation

    /// Installs the continuation before starting EventKit. A cancellation that arrived first is
    /// delivered immediately and tells the caller not to create a request.
    func installContinuation(_ continuation: Continuation) -> Bool {
        let shouldStart: Bool
        let shouldCancel: Bool

        lock.lock()
        switch state {
        case .awaitingContinuation:
            state = .awaitingRequest(continuation)
            shouldStart = true
            shouldCancel = false
        case .cancellationPending:
            state = .terminal
            shouldStart = false
            shouldCancel = true
        case .awaitingRequest, .active, .cancelledAwaitingRequest, .terminal:
            shouldStart = false
            shouldCancel = false
        }
        lock.unlock()

        if shouldCancel {
            continuation.resume(throwing: CancellationError())
        }
        return shouldStart
    }

    /// Arms cancellation after EventKit returns its opaque request token. If task cancellation won
    /// during the synchronous `fetchReminders` call, cancel the late token immediately.
    func installRequestCancellation(_ action: @escaping CancelAction) {
        let shouldCancel: Bool

        lock.lock()
        switch state {
        case .awaitingRequest(let continuation):
            state = .active(continuation, action)
            shouldCancel = false
        case .cancelledAwaitingRequest:
            state = .terminal
            shouldCancel = true
        case .awaitingContinuation, .active, .cancellationPending, .terminal:
            // A synchronous callback can complete before the request token is returned. In that
            // case the completed request must not be cancelled after the fact.
            shouldCancel = false
        }
        lock.unlock()

        if shouldCancel {
            action()
        }
    }

    func complete(_ result: Result<Value, Error>) {
        let continuation: Continuation?

        lock.lock()
        switch state {
        case .awaitingRequest(let pending), .active(let pending, _):
            state = .terminal
            continuation = pending
        case .awaitingContinuation, .cancellationPending, .cancelledAwaitingRequest, .terminal:
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(with: result)
    }

    func cancel() {
        let continuation: Continuation?
        let cancelAction: CancelAction?

        lock.lock()
        switch state {
        case .awaitingContinuation:
            state = .cancellationPending
            continuation = nil
            cancelAction = nil
        case .awaitingRequest(let pending):
            state = .cancelledAwaitingRequest
            continuation = pending
            cancelAction = nil
        case .active(let pending, let action):
            state = .terminal
            continuation = pending
            cancelAction = action
        case .cancellationPending, .cancelledAwaitingRequest, .terminal:
            continuation = nil
            cancelAction = nil
        }
        lock.unlock()

        cancelAction?()
        continuation?.resume(throwing: CancellationError())
    }
}
