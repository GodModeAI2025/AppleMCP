import Foundation

/// Thread-safe ownership of request IDs whose tool calls have not finished yet.
///
/// A reservation token prevents an older completion from removing or responding for a newer call
/// that legitimately reuses the same JSON-RPC ID after the older reservation is gone.
public final class M3MCPInFlightRequestRegistry: @unchecked Sendable {
    public struct Reservation: Equatable, Hashable, Sendable {
        public let requestID: M3MCPRequestID
        fileprivate let generation: UUID

        fileprivate init(requestID: M3MCPRequestID, generation: UUID = UUID()) {
            self.requestID = requestID
            self.generation = generation
        }
    }

    private struct Entry {
        let reservation: Reservation
        var cancelled: Bool
        var cancellationHandler: (@Sendable () -> Void)?
    }

    private let lock = NSLock()
    private let maximumEntries: Int
    private var entries: [M3MCPRequestID: Entry] = [:]

    public init(maximumEntries: Int = 16) {
        self.maximumEntries = max(1, maximumEntries)
    }

    /// Reserves an ID, or returns nil without disturbing the original call when it is a duplicate.
    public func reserve(_ requestID: M3MCPRequestID) -> Reservation? {
        lock.lock()
        defer { lock.unlock() }
        guard entries[requestID] == nil,
              entries.count < maximumEntries
        else { return nil }

        let reservation = Reservation(requestID: requestID)
        entries[requestID] = Entry(
            reservation: reservation,
            cancelled: false,
            cancellationHandler: nil
        )
        return reservation
    }

    /// Attaches the transport cancellation action. If cancellation won the race, the action is
    /// invoked immediately after releasing the lock.
    @discardableResult
    public func attachCancellationHandler(
        to reservation: Reservation,
        _ handler: @escaping @Sendable () -> Void
    ) -> Bool {
        var invokeImmediately = false

        lock.lock()
        if var entry = entries[reservation.requestID],
           entry.reservation == reservation,
           entry.cancellationHandler == nil {
            if entry.cancelled {
                invokeImmediately = true
            } else {
                entry.cancellationHandler = handler
                entries[reservation.requestID] = entry
            }
            lock.unlock()
            if invokeImmediately { handler() }
            return true
        }
        lock.unlock()
        return false
    }

    /// Marks an in-flight request cancelled and interrupts its transport at most once.
    @discardableResult
    public func cancel(_ requestID: M3MCPRequestID) -> Bool {
        var handler: (@Sendable () -> Void)?

        lock.lock()
        guard var entry = entries[requestID] else {
            lock.unlock()
            return false
        }
        if !entry.cancelled {
            entry.cancelled = true
            handler = entry.cancellationHandler
            entry.cancellationHandler = nil
            entries[requestID] = entry
        }
        lock.unlock()

        handler?()
        return true
    }

    /// Removes the exact reservation. True means its response is still wanted; false suppresses a
    /// cancelled or stale completion.
    @discardableResult
    public func finish(_ reservation: Reservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[reservation.requestID],
              entry.reservation == reservation
        else {
            return false
        }
        entries.removeValue(forKey: reservation.requestID)
        return !entry.cancelled
    }

    public func isInFlight(_ requestID: M3MCPRequestID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[requestID] != nil
    }

    /// Checks whether the exact reservation still wants a response without releasing its admission
    /// slot. Writers use this immediately before a bounded stdout write so backpressure cannot make
    /// completed calls disappear from the 16-call limit while their responses are still queued.
    public func responseIsWanted(_ reservation: Reservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[reservation.requestID] else { return false }
        return entry.reservation == reservation && !entry.cancelled
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Used when stdin closes. Handlers run outside the lock so transport shutdown cannot deadlock
    /// registry cleanup.
    public func cancelAll() {
        var handlers: [@Sendable () -> Void] = []

        lock.lock()
        for (requestID, var entry) in entries where !entry.cancelled {
            entry.cancelled = true
            if let handler = entry.cancellationHandler {
                handlers.append(handler)
            }
            entry.cancellationHandler = nil
            entries[requestID] = entry
        }
        lock.unlock()

        handlers.forEach { $0() }
    }
}
