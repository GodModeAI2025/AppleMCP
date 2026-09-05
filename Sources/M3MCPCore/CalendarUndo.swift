import Foundation

/// The event fields AppleMCP is able to write, and therefore the only ones it is able to put back.
///
/// Anything a calendar can hold that is not in this list (attendees, attachments, availability,
/// recurrence rules, travel time) is outside the undo contract because it is also outside the
/// write contract. An undo restores what these tools changed, not the event in full.
public enum M3MCPCalendarField: String, CaseIterable, Sendable {
    case title
    case allDay
    case start
    case end
    case location
    case url
    case notes
    case calendar
}

/// The value a field held before a write.
///
/// `cleared` is not the same as "absent from the record": it says the field had no value, which is
/// exactly the state an undo has to be able to restore. Collapsing the two into an optional would
/// make "there was no location" indistinguishable from "location was never touched", and an undo
/// would silently keep a location the update introduced.
public enum M3MCPCalendarPreviousValue: Equatable, Sendable {
    case text(String)
    case cleared
    case flag(Bool)
    case timestamp(Date)
}

/// Everything needed to build the event again after it has been removed.
public struct M3MCPCalendarEventSnapshot: Equatable, Sendable {
    public var title: String?
    public var isAllDay: Bool
    public var startDate: Date?
    public var endDate: Date?
    public var location: String?
    public var url: String?
    public var notes: String?
    public var calendarIdentifier: String?
    /// Relative alarm offsets in seconds, negative for "before the start".
    public var alarmOffsetsSeconds: [Double]

    public init(
        title: String? = nil,
        isAllDay: Bool = false,
        startDate: Date? = nil,
        endDate: Date? = nil,
        location: String? = nil,
        url: String? = nil,
        notes: String? = nil,
        calendarIdentifier: String? = nil,
        alarmOffsetsSeconds: [Double] = []
    ) {
        self.title = title
        self.isAllDay = isAllDay
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.url = url
        self.notes = notes
        self.calendarIdentifier = calendarIdentifier
        self.alarmOffsetsSeconds = alarmOffsetsSeconds
    }
}

/// What has to happen to put one committed write back.
public enum M3MCPCalendarUndoAction: Equatable, Sendable {
    /// Undo of a create: remove the event that was just created.
    case removeCreatedEvent(eventIdentifier: String)
    /// Undo of an update: write the recorded previous values back over the changed fields only.
    case restorePreviousValues(
        eventIdentifier: String,
        previous: [M3MCPCalendarField: M3MCPCalendarPreviousValue]
    )
    /// Undo of a delete: build the event again from its full snapshot.
    case recreateDeletedEvent(M3MCPCalendarEventSnapshot)
}

/// One committed write, with the way back.
public struct M3MCPCalendarUndoRecord: Equatable, Sendable {
    public let token: String
    public let tool: M3MCPToolName
    /// A short, already-bounded description of the write this reverses, for the undo response and
    /// the approval sheet.
    public let summary: String
    public let action: M3MCPCalendarUndoAction
    public let recordedAt: Date
    public let expiresAt: Date

    /// False when the undo cannot give the event its identifier back. Recreating a deleted event
    /// produces a new `eventIdentifier`, so anything that stored the old one still points at
    /// nothing. Callers are told this before they act on it, not after.
    public var restoresIdentifier: Bool {
        if case .recreateDeletedEvent = action { return false }
        return true
    }

    public init(
        token: String,
        tool: M3MCPToolName,
        summary: String,
        action: M3MCPCalendarUndoAction,
        recordedAt: Date,
        expiresAt: Date
    ) {
        self.token = token
        self.tool = tool
        self.summary = summary
        self.action = action
        self.recordedAt = recordedAt
        self.expiresAt = expiresAt
    }
}

/// The short-lived record of what the last few calendar writes replaced.
///
/// Approval stops a write nobody asked for. It does nothing about a write somebody asked for and got
/// wrong: the sheet is a yes/no on arguments, and once it is answered the previous state is gone.
/// This journal keeps that state for as long as a correction is plausible and no longer.
///
/// Deliberately in memory only. The snapshots hold event titles, notes, and locations, and writing
/// them to disk would create a second copy of calendar content outside the calendar, with its own
/// lifetime and its own way of leaking. Restarting the app therefore drops every token, which is
/// stated in the tool description rather than left to be discovered.
///
/// Bounded twice, because both bounds fail differently: capacity keeps a client that writes in a
/// loop from growing the process, and the lifetime keeps a token from reviving an hours-old state on
/// top of newer, deliberate edits.
public actor M3MCPCalendarUndoJournal {
    public static let defaultCapacity = 20
    public static let defaultLifetime: TimeInterval = 30 * 60

    /// What a token resolves to. The three misses stay apart because they call for different things
    /// from the caller: one has already been acted on, one is too late, one is wrong.
    public enum Lookup: Equatable, Sendable {
        case found(M3MCPCalendarUndoRecord)
        case alreadyUndone
        case expired
        case unknown
    }

    private let capacity: Int
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let makeToken: @Sendable () -> String

    /// Insertion-ordered, oldest first.
    private var records: [M3MCPCalendarUndoRecord] = []

    public init(
        capacity: Int = defaultCapacity,
        lifetime: TimeInterval = defaultLifetime,
        now: @escaping @Sendable () -> Date = { Date() },
        makeToken: @escaping @Sendable () -> String = { "cal-undo-" + UUID().uuidString.lowercased() }
    ) {
        self.capacity = max(1, capacity)
        self.lifetime = max(1, lifetime)
        self.now = now
        self.makeToken = makeToken
    }

    @discardableResult
    public func record(
        tool: M3MCPToolName,
        summary: String,
        action: M3MCPCalendarUndoAction
    ) -> M3MCPCalendarUndoRecord {
        let timestamp = now()
        let record = M3MCPCalendarUndoRecord(
            token: makeToken(),
            tool: tool,
            summary: summary,
            action: action,
            recordedAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(lifetime)
        )
        dropExpired()
        records.append(record)
        while records.count > capacity {
            records.removeFirst()
        }
        return record
    }

    /// Reads a token without spending it. This is what a dry-run undo uses, so that previewing a
    /// correction does not consume the only chance to make it.
    public func peek(token: String) -> Lookup {
        dropExpired()
        guard let record = records.first(where: { $0.token == token }) else {
            return miss(token)
        }
        return .found(record)
    }

    /// Spends a token. Single use: an undo that has run cannot run again, so a retried or replayed
    /// call cannot delete a second, newer event that happens to sit at the same identifier.
    public func consume(token: String) -> Lookup {
        dropExpired()
        guard let index = records.firstIndex(where: { $0.token == token }) else {
            return miss(token)
        }
        let record = records.remove(at: index)
        remember(token, in: &consumedTokens)
        return .found(record)
    }

    /// Puts a consumed record back when the undo it was spent on did not happen.
    ///
    /// Without this, a failed undo would be worse than no undo: the token is gone, the state is
    /// unchanged, and the caller has lost the only way back. Expired records stay dropped, so this
    /// cannot extend a lifetime.
    public func reinstate(_ record: M3MCPCalendarUndoRecord) {
        guard record.expiresAt > now() else { return }
        guard !records.contains(where: { $0.token == record.token }) else { return }
        consumedTokens.remove(record.token)
        records.append(record)
        while records.count > capacity {
            records.removeFirst()
        }
    }

    public var count: Int {
        records.count
    }

    /// Token names only, so a miss can be reported for what it is instead of as "unknown". No
    /// snapshot content survives in either set: no title, no notes, no location.
    private var expiredTokens: Set<String> = []
    private var consumedTokens: Set<String> = []

    private func dropExpired() {
        let current = now()
        var stillValid: [M3MCPCalendarUndoRecord] = []
        stillValid.reserveCapacity(records.count)
        for record in records {
            if record.expiresAt > current {
                stillValid.append(record)
            } else {
                remember(record.token, in: &expiredTokens)
            }
        }
        records = stillValid
    }

    private func miss(_ token: String) -> Lookup {
        if consumedTokens.contains(token) { return .alreadyUndone }
        if expiredTokens.contains(token) { return .expired }
        return .unknown
    }

    /// Bounded like the journal itself: these sets are a diagnostic, not a ledger.
    private func remember(_ token: String, in set: inout Set<String>) {
        set.insert(token)
        while set.count > capacity * 4, let evictable = set.first(where: { $0 != token }) {
            set.remove(evictable)
        }
    }
}
