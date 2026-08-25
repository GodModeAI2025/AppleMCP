import AppKit
import EventKit
import Foundation
import M3MCPCore

final class CalendarProvider {
    private let store = EKEventStore()

    // MARK: - Read

    func search(input: [String: JSONValue]) async -> ToolResponse {
        switch await access(need: .read) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let query = StringSanitizer.lower(input.string("query"))
        let limit = max(1, min(input.int("limit", default: 25), 100))
        let startDays = input.int("start_days", default: -7)
        let endDays = input.int("end_days", default: 60)
        let start = Calendar.current.date(byAdding: .day, value: startDays, to: Date()) ?? Date()
        let end = Calendar.current.date(byAdding: .day, value: endDays, to: Date())
            ?? Date().addingTimeInterval(60 * 60 * 24 * 60)

        let calendars: [EKCalendar]?
        if let named = input["calendar"]?.stringValue ?? input["calendar_id"]?.stringValue,
           !named.isEmpty {
            guard let calendar = resolveCalendar(idOrTitle: named) else {
                return failure("No calendar matches '\(named)'. Use calendar_list_calendars to see the available ones.")
            }
            calendars = [calendar]
        } else {
            calendars = nil
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
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

        return ToolResponse(ok: true, source: "EventKit", items: events.map(item(for:)))
    }

    /// Reads one event by the identifier `calendar_search` and the write tools return.
    ///
    /// `calendar_search` cannot stand in for this: it scans a date window, so reading back an event
    /// that was just moved outside that window would report it as gone.
    func readEvent(input: [String: JSONValue]) async -> ToolResponse {
        switch await access(need: .read) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let id = input.string("id")
        guard !id.isEmpty else {
            return failure("'id' is required.")
        }
        guard let event = store.event(withIdentifier: id) else {
            return failure("No event with id '\(id)'.")
        }

        return ToolResponse(ok: true, source: "EventKit", items: [item(for: event)])
    }

    func listCalendars(input: [String: JSONValue]) async -> ToolResponse {
        switch await access(need: .read) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let query = StringSanitizer.lower(input.string("query"))
        let writableOnly = input.bool("writable_only", default: false)
        let defaultCalendarID = store.defaultCalendarForNewEvents?.calendarIdentifier

        let calendars = store.calendars(for: .event)
            .filter { calendar in
                if writableOnly, !calendar.allowsContentModifications { return false }
                guard !query.isEmpty else { return true }
                return calendar.title.localizedLowercase.contains(query)
                    || calendar.source.title.localizedLowercase.contains(query)
            }
            .sorted { $0.title.localizedLowercase < $1.title.localizedLowercase }

        let items = calendars.map { calendar in
            DataItem(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                subtitle: calendar.source.title,
                kind: "calendar",
                source: "EventKit",
                preview: calendar.allowsContentModifications ? "writable" : "read-only",
                metadata: [
                    "source": calendar.source.title,
                    "source_type": describe(calendar.source.sourceType),
                    "writable": String(calendar.allowsContentModifications),
                    "immutable": String(calendar.isImmutable),
                    "is_default_for_new_events": String(calendar.calendarIdentifier == defaultCalendarID)
                ]
            )
        }

        return ToolResponse(ok: true, source: "EventKit", items: items)
    }

    // MARK: - Write: events

    func createEvent(input: [String: JSONValue]) async -> ToolResponse {
        switch await access(need: .write) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let title = input.string("title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return failure("'title' is required and must not be blank.")
        }

        let isAllDay = input.bool("all_day", default: false)

        guard let start = date(from: input.string("start"), allDay: isAllDay) else {
            return failure("'start' is required and must be an ISO 8601 timestamp, or YYYY-MM-DD when all_day is true.")
        }

        let end: Date
        if let parsed = date(from: input.string("end"), allDay: isAllDay) {
            end = parsed
        } else if let minutes = input["duration_minutes"]?.intValue, minutes > 0 {
            end = start.addingTimeInterval(TimeInterval(minutes * 60))
        } else if isAllDay {
            end = start
        } else {
            return failure("Supply 'end' as an ISO 8601 timestamp, or 'duration_minutes' as a positive integer.")
        }

        guard end >= start else {
            return failure("'end' is before 'start'.")
        }

        let calendar: EKCalendar
        if let named = input["calendar_id"]?.stringValue ?? input["calendar"]?.stringValue,
           !named.isEmpty {
            guard let resolved = resolveCalendar(idOrTitle: named) else {
                return failure("No calendar matches '\(named)'. Use calendar_list_calendars to see the available ones.")
            }
            calendar = resolved
        } else if let fallback = store.defaultCalendarForNewEvents {
            calendar = fallback
        } else {
            return failure("There is no default calendar for new events. Pass 'calendar' or 'calendar_id'.")
        }

        guard calendar.allowsContentModifications else {
            return failure("Calendar '\(calendar.title)' is read-only.")
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.isAllDay = isAllDay
        event.startDate = start
        event.endDate = end

        if let location = input["location"]?.stringValue, !location.isEmpty {
            event.location = location
        }
        if let urlString = input["url"]?.stringValue, !urlString.isEmpty {
            guard let url = URL(string: urlString) else {
                return failure("'url' is not a valid URL: \(urlString)")
            }
            event.url = url
        }
        if let minutes = input["alarm_minutes_before"]?.intValue {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }

        let suppliedNotes = input["notes"]?.stringValue
        if let slug = input["project_slug"]?.stringValue, !slug.isEmpty {
            guard let notes = CalendarProjectSlug.embed(slug: slug, in: suppliedNotes) else {
                return failure(invalidSlugMessage(slug))
            }
            event.notes = notes
        } else if let suppliedNotes, !suppliedNotes.isEmpty {
            event.notes = suppliedNotes
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return failure("Could not save the event: \(error.localizedDescription)")
        }

        return ToolResponse(
            ok: true,
            source: "EventKit",
            items: [item(for: event)],
            message: "Created '\(title)' in '\(calendar.title)'."
        )
    }

    /// Changes only the fields present in `input`. An absent field is left alone; that is what makes
    /// this safe to call on an event the caller did not create.
    func updateEvent(input: [String: JSONValue]) async -> ToolResponse {
        switch await access(need: .write) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let id = input.string("id")
        guard !id.isEmpty else {
            return failure("'id' is required.")
        }
        guard let event = store.event(withIdentifier: id) else {
            return failure("No event with id '\(id)'.")
        }
        guard event.calendar.allowsContentModifications else {
            return failure("Event '\(event.title ?? id)' is in read-only calendar '\(event.calendar.title)'.")
        }

        var changed: [String] = []

        if let title = input["title"]?.stringValue {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return failure("'title' must not be blank.")
            }
            event.title = trimmed
            changed.append("title")
        }

        // Applied before the dates, so switching a timed event to all-day parses YYYY-MM-DD.
        if let allDay = input["all_day"]?.boolValue {
            event.isAllDay = allDay
            changed.append("all_day")
        }

        if let raw = input["start"]?.stringValue {
            guard let start = date(from: raw, allDay: event.isAllDay) else {
                return failure("'start' is not an ISO 8601 timestamp: \(raw)")
            }
            event.startDate = start
            changed.append("start")
        }

        if let raw = input["end"]?.stringValue {
            guard let end = date(from: raw, allDay: event.isAllDay) else {
                return failure("'end' is not an ISO 8601 timestamp: \(raw)")
            }
            event.endDate = end
            changed.append("end")
        } else if let minutes = input["duration_minutes"]?.intValue, minutes > 0 {
            event.endDate = event.startDate.addingTimeInterval(TimeInterval(minutes * 60))
            changed.append("end")
        }

        guard event.endDate >= event.startDate else {
            return failure("The resulting 'end' is before 'start'.")
        }

        if let location = input["location"]?.stringValue {
            event.location = location.isEmpty ? nil : location
            changed.append("location")
        }

        if let urlString = input["url"]?.stringValue {
            if urlString.isEmpty {
                event.url = nil
            } else {
                guard let url = URL(string: urlString) else {
                    return failure("'url' is not a valid URL: \(urlString)")
                }
                event.url = url
            }
            changed.append("url")
        }

        // notes and project_slug write the same field, so they are resolved together.
        let notesGiven = input["notes"]?.stringValue
        let slugGiven = input["project_slug"]?.stringValue
        if notesGiven != nil || slugGiven != nil {
            var body = notesGiven ?? CalendarProjectSlug.remove(from: event.notes)
            if notesGiven != nil { changed.append("notes") }

            if let slugGiven {
                if slugGiven.isEmpty {
                    body = CalendarProjectSlug.remove(from: body)
                    event.notes = (body?.isEmpty ?? true) ? nil : body
                } else {
                    guard let notes = CalendarProjectSlug.embed(slug: slugGiven, in: body) else {
                        return failure(invalidSlugMessage(slugGiven))
                    }
                    event.notes = notes
                }
                changed.append("project_slug")
            } else if let existing = CalendarProjectSlug.extract(from: event.notes) {
                // Rewriting notes must not silently drop a slug the caller did not mention.
                event.notes = CalendarProjectSlug.embed(slug: existing, in: body)
            } else {
                event.notes = (body?.isEmpty ?? true) ? nil : body
            }
        }

        if let named = input["calendar_id"]?.stringValue ?? input["calendar"]?.stringValue,
           !named.isEmpty {
            guard let target = resolveCalendar(idOrTitle: named) else {
                return failure("No calendar matches '\(named)'. Use calendar_list_calendars to see the available ones.")
            }
            guard target.allowsContentModifications else {
                return failure("Calendar '\(target.title)' is read-only.")
            }
            event.calendar = target
            changed.append("calendar")
        }

        guard !changed.isEmpty else {
            return failure("Nothing to change. Pass at least one of title, start, end, duration_minutes, all_day, location, url, notes, project_slug, calendar.")
        }

        do {
            try store.save(event, span: span(from: input), commit: true)
        } catch {
            return failure("Could not save the event: \(error.localizedDescription)")
        }

        return ToolResponse(
            ok: true,
            source: "EventKit",
            items: [item(for: event)],
            message: "Updated \(changed.joined(separator: ", "))."
        )
    }

    func deleteEvent(input: [String: JSONValue]) async -> ToolResponse {
        switch await access(need: .write) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let id = input.string("id")
        guard !id.isEmpty else {
            return failure("'id' is required.")
        }
        guard let event = store.event(withIdentifier: id) else {
            return failure("No event with id '\(id)'.")
        }
        guard event.calendar.allowsContentModifications else {
            return failure("Event '\(event.title ?? id)' is in read-only calendar '\(event.calendar.title)'.")
        }

        let title = event.title ?? "(untitled event)"
        let calendarTitle = event.calendar.title

        do {
            try store.remove(event, span: span(from: input), commit: true)
        } catch {
            return failure("Could not delete the event: \(error.localizedDescription)")
        }

        return ToolResponse(
            ok: true,
            source: "EventKit",
            message: "Deleted '\(title)' from '\(calendarTitle)'."
        )
    }

    // MARK: - Write: calendars

    /// Creates a calendar, defaulting to the on-device source.
    ///
    /// Defaulting to local is deliberate: a calendar created in a synced source propagates to the
    /// account's other devices and to whoever that account shares with. Anything scratch — a test
    /// calendar above all — belongs on the machine that made it.
    func createCalendar(input: [String: JSONValue]) async -> ToolResponse {
        switch await access(need: .write) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let title = input.string("title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return failure("'title' is required and must not be blank.")
        }

        if let existing = store.calendars(for: .event).first(where: { $0.title == title }) {
            return failure("A calendar called '\(title)' already exists (id \(existing.calendarIdentifier)).")
        }

        let requestedSource = input.string("source")
        let source: EKSource?
        if !requestedSource.isEmpty {
            source = store.sources.first { $0.title == requestedSource }
            guard source != nil else {
                let available = store.sources.map(\.title).joined(separator: ", ")
                return failure("No source called '\(requestedSource)'. Available: \(available).")
            }
        } else {
            // Local only. Falling back to the default calendar's source would put a new calendar in
            // whichever account happens to be default — measured on a machine with no local source,
            // where the fallback aimed at a synced work account that then refused the write anyway.
            // A calendar is not something to create in an account by accident, so this asks instead.
            source = store.sources.first { $0.sourceType == .local }
        }

        guard let source else {
            let candidates = store.sources
                .filter { !$0.calendars(for: .event).filter(\.allowsContentModifications).isEmpty }
                .map { "'\($0.title)' (\(describe($0.sourceType)))" }
                .joined(separator: ", ")
            return failure(
                "There is no local ('On My Mac') calendar source, so there is nowhere to create a "
                + "calendar that does not sync to an account. Enable it in Calendar.app › Settings › "
                + "General, or pass 'source' explicitly to accept the sync. Sources holding writable "
                + "calendars: \(candidates.isEmpty ? "none" : candidates)."
            )
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source

        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            return failure("Could not create calendar '\(title)' in source '\(source.title)': \(error.localizedDescription)")
        }

        return ToolResponse(
            ok: true,
            source: "EventKit",
            items: [
                DataItem(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    subtitle: source.title,
                    kind: "calendar",
                    source: "EventKit",
                    preview: "writable",
                    metadata: [
                        "source": source.title,
                        "source_type": describe(source.sourceType),
                        "writable": String(calendar.allowsContentModifications)
                    ]
                )
            ],
            message: "Created calendar '\(title)' in source '\(source.title)'."
        )
    }

    /// Deletes a calendar and everything in it, and requires the caller to name it twice.
    ///
    /// `id` and `title` must both be given and must agree. Deleting a calendar destroys its events
    /// with no undo, and an identifier alone is easy to carry over from a stale listing — so the
    /// second key is what proves the caller means *this* calendar.
    func deleteCalendar(input: [String: JSONValue]) async -> ToolResponse {
        switch await access(need: .write) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let id = input.string("id")
        let title = input.string("title")
        guard !id.isEmpty, !title.isEmpty else {
            return failure("Both 'id' and 'title' are required: deleting a calendar destroys its events, so it takes two matching keys.")
        }
        guard let calendar = store.calendar(withIdentifier: id) else {
            return failure("No calendar with id '\(id)'.")
        }
        guard calendar.title == title else {
            return failure("Refusing to delete: calendar '\(id)' is titled '\(calendar.title)', not '\(title)'.")
        }
        guard !calendar.isImmutable else {
            return failure("Calendar '\(calendar.title)' is immutable and cannot be deleted.")
        }

        do {
            try store.removeCalendar(calendar, commit: true)
        } catch {
            return failure("Could not delete calendar '\(title)': \(error.localizedDescription)")
        }

        return ToolResponse(ok: true, source: "EventKit", message: "Deleted calendar '\(title)'.")
    }

    // MARK: - Access

    private enum Need {
        case read
        case write
    }

    private enum Access {
        case granted
        case denied(ToolResponse)
    }

    private enum RequestOutcome {
        case granted
        case refused
        case timedOut
        case failed(String)
    }

    /// How long to wait for the macOS permission dialog before giving up.
    ///
    /// A TCC request whose dialog nobody answers never calls its completion handler. Left unbounded
    /// that hangs the MCP call for as long as the client will wait, which reads as a broken server
    /// rather than as a missing permission. Bounding it turns the hang into an error that names the
    /// fix. Override with `M3MCP_TCC_REQUEST_TIMEOUT_SECONDS`.
    private var requestTimeout: TimeInterval {
        let key = "M3MCP_TCC_REQUEST_TIMEOUT_SECONDS"
        if let raw = ProcessInfo.processInfo.environment[key], let value = TimeInterval(raw), value > 0 {
            return value
        }
        return 20
    }

    /// Gates every call on the authorization status, and only prompts when the status is undetermined.
    ///
    /// The previous version called `requestFullAccessToEvents` on every search. That re-activated the
    /// app on each call, and after a denial it asked an already-answered question instead of saying
    /// what was wrong.
    private func access(need: Need) async -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .granted

        case .writeOnly:
            // Write-only is enough to add an event and not enough to read one back.
            if need == .write {
                return .granted
            }
            return .denied(failure("Calendar access is write-only. Reading events needs full access: System Settings › Privacy & Security › Calendars."))

        case .denied:
            return .denied(failure("Calendar access is denied. Grant it in System Settings › Privacy & Security › Calendars, then restart M3MCP."))

        case .restricted:
            return .denied(failure("Calendar access is restricted by a device policy."))

        case .notDetermined:
            return await requestAccess(need: need)

        @unknown default:
            return .denied(failure("Calendar authorization status is not recognised by this build."))
        }
    }

    @MainActor
    private func requestAccess(need: Need) async -> Access {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let timeout = requestTimeout
        let outcome: RequestOutcome = await withCheckedContinuation { continuation in
            let gate = OneShotContinuation(continuation)

            store.requestFullAccessToEvents { granted, error in
                if let error {
                    gate.resume(.failed(error.localizedDescription))
                } else {
                    gate.resume(granted ? .granted : .refused)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                gate.resume(.timedOut)
            }
        }

        switch outcome {
        case .granted:
            return .granted
        case .refused:
            return .denied(failure("Calendar access was not granted."))
        case .failed(let message):
            return .denied(failure("Requesting Calendar access failed: \(message)"))
        case .timedOut:
            let requested = need == .write ? "write" : "read"
            return .denied(failure(
                "Calendar access is still undetermined after \(Int(timeout))s — the macOS permission "
                + "dialog was not answered. Approve it, or grant M3MCP access under System Settings › "
                + "Privacy & Security › Calendars, then retry. (Requested: \(requested).)"
            ))
        }
    }

    /// Resumes a continuation exactly once, so the timeout and the completion handler can race.
    private final class OneShotContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<RequestOutcome, Never>?

        init(_ continuation: CheckedContinuation<RequestOutcome, Never>) {
            self.continuation = continuation
        }

        func resume(_ outcome: RequestOutcome) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }

    // MARK: - Helpers

    private func failure(_ message: String) -> ToolResponse {
        ToolResponse(ok: false, source: "EventKit", message: message)
    }

    private func invalidSlugMessage(_ slug: String) -> String {
        "'project_slug' must be 1-64 characters, start with a lowercase letter or digit, and hold only a-z, 0-9, '-', '_' and '.'; got '\(slug)'."
    }

    private func resolveCalendar(idOrTitle: String) -> EKCalendar? {
        if let byID = store.calendar(withIdentifier: idOrTitle) {
            return byID
        }
        let calendars = store.calendars(for: .event)
        return calendars.first { $0.title == idOrTitle }
            ?? calendars.first { $0.title.localizedLowercase == idOrTitle.localizedLowercase }
    }

    private func span(from input: [String: JSONValue]) -> EKSpan {
        input.string("span", default: "this_event") == "future_events" ? .futureEvents : .thisEvent
    }

    /// Accepts an ISO 8601 timestamp, a zone-less local timestamp, and `YYYY-MM-DD` for all-day.
    private func date(from raw: String, allDay: Bool) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) {
            return date
        }

        // A timestamp with no zone designator is local time — the timezone the Calendar UI shows.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: trimmed) {
                return date
            }
        }

        guard allDay else { return nil }
        local.dateFormat = "yyyy-MM-dd"
        return local.date(from: trimmed)
    }

    private func item(for event: EKEvent) -> DataItem {
        let formatter = ISO8601DateFormatter()
        var metadata: [String: String] = [
            "calendar": event.calendar.title,
            "calendar_id": event.calendar.calendarIdentifier,
            "start": formatter.string(from: event.startDate),
            "end": formatter.string(from: event.endDate),
            "all_day": String(event.isAllDay)
        ]
        if let url = event.url?.absoluteString {
            metadata["url"] = url
        }
        if let slug = CalendarProjectSlug.extract(from: event.notes) {
            metadata["project_slug"] = slug
        }

        return DataItem(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "(untitled event)",
            subtitle: event.location,
            kind: "calendar_event",
            source: "EventKit",
            preview: StringSanitizer.compact(event.notes ?? "", limit: 900),
            metadata: metadata
        )
    }

    private func describe(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "mobileme"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }
}
