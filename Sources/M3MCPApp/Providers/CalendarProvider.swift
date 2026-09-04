import EventKit
import Foundation
import M3MCPCore

final class CalendarProvider {
    static let maximumQueryUTF8Bytes = 4_096
    static let defaultSearchCandidates = 2_000
    static let maximumSearchCandidates = 5_000
    static let maximumSearchFieldUTF8Bytes = 16 * 1_024
    static let maximumListedCalendars = 400
    static let maximumIdentifierUTF8Bytes = 512
    static let maximumTitleUTF8Bytes = 1_024
    static let maximumSubtitleUTF8Bytes = 1_024
    static let maximumPreviewUTF8Bytes = 4_096
    static let maximumURLUTF8Bytes = 2_048

    private let store = EKEventStore()

    // MARK: - Read

    func search(input: [String: JSONValue]) async -> ToolResponse {
        guard !Task.isCancelled else {
            return failure("Calendar request was cancelled.")
        }
        let rawQuery = input.string("query")
        guard rawQuery.utf8.count <= Self.maximumQueryUTF8Bytes else {
            return failure("Calendar query exceeds the \(Self.maximumQueryUTF8Bytes)-byte work limit.")
        }
        switch await access(need: .read) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let query = StringSanitizer.lower(rawQuery)
        let limit = max(1, min(input.int("limit", default: 25), 100))
        let maxCandidates = Self.searchCandidateLimit(input: input)
        let startDays = max(-3_650, min(input.int("start_days", default: -7), 3_650))
        let endDays = max(-3_650, min(input.int("end_days", default: 60), 3_650))
        guard endDays > startDays else {
            return failure("'end_days' must be greater than 'start_days'.")
        }
        let start = Calendar.current.date(byAdding: .day, value: startDays, to: Date()) ?? Date()
        let end = Calendar.current.date(byAdding: .day, value: endDays, to: Date())
            ?? Date().addingTimeInterval(60 * 60 * 24 * 60)

        let calendars: [EKCalendar]?
        if let named = input["calendar"]?.stringValue ?? input["calendar_id"]?.stringValue,
           !named.isEmpty {
            switch resolveCalendar(idOrTitle: named) {
            case .found(let resolved):
                calendars = [resolved]
            case .notFound:
                return failure("No calendar matches '\(named)'. Use calendar_list_calendars to see the available ones.")
            case .ambiguous:
                return failure("More than one calendar is titled '\(named)'. Pass the exact calendar_id from calendar_list_calendars.")
            }
        } else {
            calendars = nil
        }

        var cursor = start
        var scanned = 0
        var scanCapped = false
        var searchContentCapped = false
        var matched: [EKEvent] = []
        var seen = Set<String>()

        // EventKit cannot limit `events(matching:)`. Seven-day chunks bound each framework result
        // much more tightly than the former single twenty-year query, while the provider stops
        // inspecting after an absolute candidate budget and reports a partial result.
        while cursor < end, scanned < maxCandidates {
            guard !Task.isCancelled else { return failure("Calendar request was cancelled.") }
            let proposedEnd = Calendar.current.date(byAdding: .day, value: 7, to: cursor) ?? end
            let chunkEnd = min(proposedEnd, end)
            let predicate = store.predicateForEvents(
                withStart: cursor,
                end: chunkEnd,
                calendars: calendars
            )
            let chunk = store.events(matching: predicate)

            for (index, event) in chunk.enumerated() {
                guard !Task.isCancelled else { return failure("Calendar request was cancelled.") }
                guard scanned < maxCandidates else {
                    scanCapped = true
                    break
                }
                scanned += 1
                let key = "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSinceReferenceDate)|\(event.endDate.timeIntervalSinceReferenceDate)"
                guard seen.insert(key).inserted else { continue }

                if !query.isEmpty {
                    let fields = [event.title, event.location, event.notes, event.calendar.title]
                        .compactMap { $0 }
                        .map {
                            ProviderOutputBudget.text(
                                $0,
                                maximumUTF8Bytes: Self.maximumSearchFieldUTF8Bytes
                            )
                        }
                    searchContentCapped = searchContentCapped || fields.contains(where: \.truncated)
                    let haystack = fields.map(\.text).joined(separator: " ").localizedLowercase
                    guard haystack.contains(query) else { continue }
                }
                matched.append(event)

                if scanned == maxCandidates,
                   index + 1 < chunk.count || chunkEnd < end {
                    scanCapped = true
                }
            }
            cursor = chunkEnd
        }
        if cursor < end { scanCapped = true }

        matched.sort { $0.startDate < $1.startDate }
        let selected = Array(matched.prefix(limit))
        let items = selected.map(item(for:))
        let hasMore = matched.count > items.count || scanCapped
        let message = scanCapped
            ? "Calendar search reached its \(maxCandidates)-event scan budget; narrow the date range, query, or calendar."
            : (searchContentCapped
                ? "Some event fields exceeded the per-field search budget; matches beyond those prefixes were not inspected."
                : (matched.count > items.count ? "More events matched; increase limit." : nil))
        return ToolResponse(
            ok: true,
            source: "EventKit",
            items: items,
            message: message,
            meta: [
                "returned": String(items.count),
                "matching_in_scan": String(matched.count),
                "scanned": String(scanned),
                "scan_budget": String(maxCandidates),
                "scan_capped": String(scanCapped),
                "search_content_capped": String(searchContentCapped),
                "total_exact": String(!scanCapped),
                "has_more": String(hasMore),
                "truncated": String(hasMore || searchContentCapped)
            ]
        )
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
        guard !Task.isCancelled else {
            return failure("Calendar request was cancelled.")
        }
        let rawQuery = input.string("query")
        guard rawQuery.utf8.count <= Self.maximumQueryUTF8Bytes else {
            return failure("Calendar query exceeds the \(Self.maximumQueryUTF8Bytes)-byte work limit.")
        }
        switch await access(need: .read) {
        case .denied(let response):
            return response
        case .granted:
            break
        }

        let query = StringSanitizer.lower(rawQuery)
        let writableOnly = input.bool("writable_only", default: false)
        let defaultCalendarID = store.defaultCalendarForNewEvents?.calendarIdentifier

        let allCalendars = store.calendars(for: .event)
        let scanCapped = allCalendars.count > Self.maximumListedCalendars
        let calendars = allCalendars.prefix(Self.maximumListedCalendars)
            .filter { calendar in
                if writableOnly, !calendar.allowsContentModifications { return false }
                guard !query.isEmpty else { return true }
                return calendar.title.localizedLowercase.contains(query)
                    || calendar.source.title.localizedLowercase.contains(query)
            }
            .sorted { $0.title.localizedLowercase < $1.title.localizedLowercase }

        let items = calendars.map { calendarItem(for: $0, defaultCalendarID: defaultCalendarID) }

        return ToolResponse(
            ok: true,
            source: "EventKit",
            items: items,
            message: scanCapped
                ? "Calendar listing inspected only the first \(Self.maximumListedCalendars) framework-provided calendars; later calendars are not reachable in this call."
                : nil,
            meta: [
                "returned": String(items.count),
                "framework_returned": String(allCalendars.count),
                "scan_budget": String(Self.maximumListedCalendars),
                "scan_capped": String(scanCapped),
                "truncated": String(scanCapped)
            ]
        )
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

        let durationMinutes = input["duration_minutes"]?.intValue
        if let durationMinutes, !(1...525_600).contains(durationMinutes) {
            return failure("'duration_minutes' must be between 1 and 525600.")
        }
        let explicitEnd: Date?
        switch explicitEndValue(from: input["end"]?.stringValue, allDay: isAllDay) {
        case .omitted:
            explicitEnd = nil
        case .parsed(let parsed):
            explicitEnd = parsed
        case .invalid:
            return failure("When supplied, 'end' must be a valid ISO 8601 timestamp, or YYYY-MM-DD when all_day is true. Omit it to use duration_minutes or the all-day default.")
        }
        guard let end = CalendarEventTiming.resolvedEnd(
            start: start,
            explicitEnd: explicitEnd,
            durationMinutes: durationMinutes,
            isAllDay: isAllDay
        ) else {
            return failure("Supply 'end' as an ISO 8601 timestamp, or 'duration_minutes' as a positive integer.")
        }

        guard CalendarEventTiming.isValid(start: start, end: end) else {
            return failure("'end' must be after 'start'. For all-day events, 'end' is the exclusive following date.")
        }

        guard let named = input["calendar_id"]?.stringValue ?? input["calendar"]?.stringValue,
              !named.isEmpty else {
            return failure("'calendar_id' is required for creation so an event cannot land in a default account by accident.")
        }
        let calendar: EKCalendar
        switch resolveCalendar(idOrTitle: named) {
        case .found(let resolved):
            calendar = resolved
        case .notFound:
            return failure("No calendar matches '\(named)'. Use calendar_list_calendars to see the available ones.")
        case .ambiguous:
            return failure("More than one calendar is titled '\(named)'. Pass the exact calendar_id from calendar_list_calendars.")
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
            guard (0...525_600).contains(minutes) else {
                return failure("'alarm_minutes_before' must be between 0 and 525600.")
            }
            event.addAlarm(EKAlarm(relativeOffset: -TimeInterval(minutes) * 60))
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

        guard !Task.isCancelled else {
            return cancelledBeforeWrite("event creation")
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

        guard let recurrenceSpan = recurrenceSpan(from: input) else {
            return failure("'span' must be either 'this_event' or 'future_events'.")
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
        } else if let minutes = input["duration_minutes"]?.intValue {
            guard (1...525_600).contains(minutes) else {
                return failure("'duration_minutes' must be between 1 and 525600.")
            }
            event.endDate = event.startDate.addingTimeInterval(TimeInterval(minutes) * 60)
            changed.append("end")
        }

        guard CalendarEventTiming.isValid(start: event.startDate, end: event.endDate) else {
            return failure("The resulting 'end' must be after 'start'.")
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
            let target: EKCalendar
            switch resolveCalendar(idOrTitle: named) {
            case .found(let resolved):
                target = resolved
            case .notFound:
                return failure("No calendar matches '\(named)'. Use calendar_list_calendars to see the available ones.")
            case .ambiguous:
                return failure("More than one calendar is titled '\(named)'. Pass the exact calendar_id from calendar_list_calendars.")
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

        guard !Task.isCancelled else {
            return cancelledBeforeWrite("event update")
        }
        do {
            try store.save(event, span: recurrenceSpan, commit: true)
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

        guard let recurrenceSpan = recurrenceSpan(from: input) else {
            return failure("'span' must be either 'this_event' or 'future_events'.")
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

        guard !Task.isCancelled else {
            return cancelledBeforeWrite("event deletion")
        }
        do {
            try store.remove(event, span: recurrenceSpan, commit: true)
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

        guard !Task.isCancelled else {
            return cancelledBeforeWrite("calendar creation")
        }
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

        guard !Task.isCancelled else {
            return cancelledBeforeWrite("calendar deletion")
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

    /// Gates calls on current authorization without ever displaying a TCC prompt. Prompting is an
    /// externally visible side effect and is confined to the separately policy-gated
    /// `permissions_request` tool.
    private func access(need: Need) async -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .granted

        case .writeOnly:
            if need == .write {
                return .denied(failure(
                    "Calendar access is write-only. These guarded write tools first resolve and verify existing calendars or events, so they require full access: System Settings › Privacy & Security › Calendars."
                ))
            }
            return .denied(failure("Calendar access is write-only. Reading events needs full access: System Settings › Privacy & Security › Calendars."))

        case .denied:
            return .denied(failure("Calendar access is denied. Grant it in System Settings › Privacy & Security › Calendars, then restart M3MCP."))

        case .restricted:
            return .denied(failure("Calendar access is restricted by a device policy."))

        case .notDetermined:
            return .denied(failure(
                "Calendar access is not determined. Grant it in System Settings, or explicitly enable and call permissions_request."
            ))

        @unknown default:
            return .denied(failure("Calendar authorization status is not recognised by this build."))
        }
    }

    // MARK: - Helpers

    private func failure(_ message: String) -> ToolResponse {
        ToolResponse(ok: false, source: "EventKit", message: message)
    }

    static func searchCandidateLimit(input: [String: JSONValue]) -> Int {
        max(
            1,
            min(input.int("max_candidates", default: defaultSearchCandidates), maximumSearchCandidates)
        )
    }

    private func cancelledBeforeWrite(_ operation: String) -> ToolResponse {
        ToolResponse(
            ok: false,
            source: "EventKit",
            message: "Cancelled before the \(operation) write began."
        )
    }

    private func invalidSlugMessage(_ slug: String) -> String {
        "'project_slug' must be 1-64 characters, start with a lowercase letter or digit, and hold only a-z, 0-9, '-', '_' and '.'; got '\(slug)'."
    }

    private enum CalendarResolution {
        case found(EKCalendar)
        case notFound
        case ambiguous
    }

    private func resolveCalendar(idOrTitle: String) -> CalendarResolution {
        if let byID = store.calendar(withIdentifier: idOrTitle) {
            return .found(byID)
        }
        let calendars = store.calendars(for: .event)
        let exact = calendars.filter { $0.title == idOrTitle }
        if exact.count == 1, let calendar = exact.first { return .found(calendar) }
        if exact.count > 1 { return .ambiguous }

        let folded = calendars.filter {
            $0.title.localizedCaseInsensitiveCompare(idOrTitle) == .orderedSame
        }
        if folded.count == 1, let calendar = folded.first { return .found(calendar) }
        return folded.isEmpty ? .notFound : .ambiguous
    }

    private func recurrenceSpan(from input: [String: JSONValue]) -> EKSpan? {
        switch input.string("span", default: "this_event") {
        case "this_event":
            return .thisEvent
        case "future_events":
            return .futureEvents
        default:
            return nil
        }
    }

    enum ExplicitEndValue: Equatable {
        case omitted
        case parsed(Date)
        case invalid
    }

    /// Presence matters: a malformed approved value must not silently turn into an omitted value
    /// and activate the duration/all-day fallback.
    func explicitEndValue(from raw: String?, allDay: Bool) -> ExplicitEndValue {
        guard let raw else { return .omitted }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parsed = date(from: raw, allDay: allDay) else {
            return .invalid
        }
        return .parsed(parsed)
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

    func item(for event: EKEvent) -> DataItem {
        let formatter = ISO8601DateFormatter()
        let identifier = ProviderOutputBudget.text(
            event.eventIdentifier ?? UUID().uuidString,
            maximumUTF8Bytes: Self.maximumIdentifierUTF8Bytes
        )
        let title = ProviderOutputBudget.text(
            event.title ?? "(untitled event)",
            maximumUTF8Bytes: Self.maximumTitleUTF8Bytes
        )
        let location = ProviderOutputBudget.text(
            event.location ?? "",
            maximumUTF8Bytes: Self.maximumSubtitleUTF8Bytes
        )
        let calendarTitle = ProviderOutputBudget.text(
            event.calendar.title,
            maximumUTF8Bytes: Self.maximumSubtitleUTF8Bytes
        )
        let calendarIdentifier = ProviderOutputBudget.text(
            event.calendar.calendarIdentifier,
            maximumUTF8Bytes: Self.maximumIdentifierUTF8Bytes
        )
        let notesSource = ProviderOutputBudget.text(
            event.notes ?? "",
            maximumUTF8Bytes: Self.maximumSearchFieldUTF8Bytes
        )
        // Keep the pre-hardening preview contract (single-line, at most 900 characters), but bound
        // the source before normalization so compacting cannot allocate from an arbitrary field.
        let notes = ProviderOutputBudget.text(
            StringSanitizer.compact(notesSource.text, limit: 900),
            maximumUTF8Bytes: Self.maximumPreviewUTF8Bytes
        )
        let url = event.url.map {
            ProviderOutputBudget.text(
                $0.absoluteString,
                maximumUTF8Bytes: Self.maximumURLUTF8Bytes
            )
        }
        var metadata: [String: String] = [
            "calendar": calendarTitle.text,
            "calendar_id": calendarIdentifier.text,
            "start": formatter.string(from: event.startDate),
            "end": formatter.string(from: event.endDate),
            "all_day": String(event.isAllDay),
            "content_truncated": String(
                identifier.truncated || title.truncated || location.truncated
                    || calendarTitle.truncated || calendarIdentifier.truncated
                    || notesSource.truncated || notes.truncated || url?.truncated == true
            )
        ]
        if let url {
            metadata["url"] = url.text
        }
        if let slug = CalendarProjectSlug.extract(from: notes.text) {
            metadata["project_slug"] = slug
        }

        return DataItem(
            id: identifier.text,
            title: title.text.isEmpty ? "(untitled event)" : title.text,
            subtitle: location.text.isEmpty ? nil : location.text,
            kind: "calendar_event",
            source: "EventKit",
            preview: notes.text.isEmpty ? nil : notes.text,
            metadata: metadata
        )
    }

    func calendarItem(for calendar: EKCalendar, defaultCalendarID: String?) -> DataItem {
        let identifier = ProviderOutputBudget.text(
            calendar.calendarIdentifier,
            maximumUTF8Bytes: Self.maximumIdentifierUTF8Bytes
        )
        let title = ProviderOutputBudget.text(
            calendar.title,
            maximumUTF8Bytes: Self.maximumTitleUTF8Bytes
        )
        let source = ProviderOutputBudget.text(
            calendar.source.title,
            maximumUTF8Bytes: Self.maximumSubtitleUTF8Bytes
        )
        return DataItem(
            id: identifier.text,
            title: title.text,
            subtitle: source.text,
            kind: "calendar",
            source: "EventKit",
            preview: calendar.allowsContentModifications ? "writable" : "read-only",
            metadata: [
                "source": source.text,
                "source_type": describe(calendar.source.sourceType),
                "writable": String(calendar.allowsContentModifications),
                "immutable": String(calendar.isImmutable),
                "is_default_for_new_events": String(calendar.calendarIdentifier == defaultCalendarID),
                "content_truncated": String(identifier.truncated || title.truncated || source.truncated)
            ]
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
