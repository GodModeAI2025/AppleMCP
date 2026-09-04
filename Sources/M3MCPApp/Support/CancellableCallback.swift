import Foundation

/// Converts a one-shot callback into an async value without letting task cancellation strand the
/// caller when the underlying framework never invokes its callback after a system prompt.
///
/// Cancellation resumes the Swift continuation immediately. The native prompt/action may already
/// be in flight and cannot always be dismissed, but a late framework callback is ignored and no
/// LocalHTTP connection slot remains tied to it.
func awaitCancellableCallback<Value>(
    _ start: @escaping (@escaping (Result<Value, Error>) -> Void) -> Void
) async throws -> Value {
    try Task.checkCancellation()
    let relay = CallbackCancellationRelay<Value>()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard relay.install(continuation), relay.beginOperation() else {
                return
            }
            start { result in
                relay.complete(result)
            }
        }
    } onCancel: {
        relay.cancel()
    }
}

/// Single-resume state machine shared by callback-based TCC bridges and deterministic tests.
final class CallbackCancellationRelay<Value>: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Value, Error>

    private enum State {
        case awaitingContinuation
        case armed(Continuation)
        case running(Continuation)
        case cancellationPending
        case terminal
    }

    private let lock = NSLock()
    private var state = State.awaitingContinuation

    func install(_ continuation: Continuation) -> Bool {
        let shouldArm: Bool
        let shouldCancel: Bool

        lock.lock()
        switch state {
        case .awaitingContinuation:
            state = .armed(continuation)
            shouldArm = true
            shouldCancel = false
        case .cancellationPending:
            state = .terminal
            shouldArm = false
            shouldCancel = true
        case .armed, .running, .terminal:
            shouldArm = false
            shouldCancel = false
        }
        lock.unlock()

        if shouldCancel {
            continuation.resume(throwing: CancellationError())
        }
        return shouldArm
    }

    /// Marks the external operation live. Cancellation that won after continuation installation
    /// but before this point prevents the framework request from being started.
    func beginOperation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .armed(let continuation) = state else { return false }
        state = .running(continuation)
        return true
    }

    func complete(_ result: Result<Value, Error>) {
        let continuation: Continuation?

        lock.lock()
        switch state {
        case .armed(let pending), .running(let pending):
            state = .terminal
            continuation = pending
        case .awaitingContinuation, .cancellationPending, .terminal:
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(with: result)
    }

    func cancel() {
        let continuation: Continuation?

        lock.lock()
        switch state {
        case .awaitingContinuation:
            state = .cancellationPending
            continuation = nil
        case .armed(let pending), .running(let pending):
            state = .terminal
            continuation = pending
        case .cancellationPending, .terminal:
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
    }
}
