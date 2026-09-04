import AppKit
import Foundation

enum AppleScriptRunner {
    struct Failure: Error, Sendable {
        let message: String
    }

    private final class CompletionBox: @unchecked Sendable {
        private enum State {
            case awaitingExecution
            case executing
            case completed
        }

        private let lock = NSLock()
        private var state = State.awaitingExecution
        private let continuation: CheckedContinuation<Result<String, Failure>, Never>

        init(_ continuation: CheckedContinuation<Result<String, Failure>, Never>) {
            self.continuation = continuation
        }

        /// Claims the only potentially blocking execution. A cancellation or timeout that won
        /// before the worker started prevents AppleScript from being invoked at all.
        func beginExecution() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard case .awaitingExecution = state else {
                return false
            }
            state = .executing
            return true
        }

        func finish(_ result: Result<String, Failure>) {
            lock.lock()
            guard case .completed = state else {
                state = .completed
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            lock.unlock()
        }
    }

    static func run(_ source: String, timeout: TimeInterval = 8) async -> Result<String, Failure> {
        await run(
            source,
            timeout: timeout,
            gate: .shared,
            executor: nativeExecutor
        )
    }

    /// Injectable execution seam for cancellation/admission tests. Neither production nor tests
    /// activate M3MCP here: a default-safe Notes read must remain background-only after its
    /// prompt-free permission preflight.
    static func runForTesting(
        _ source: String,
        timeout: TimeInterval,
        gate: AppleEventExecutionGate,
        executor: @escaping @Sendable (String) -> Result<String, Failure>
    ) async -> Result<String, Failure> {
        await run(
            source,
            timeout: timeout,
            gate: gate,
            executor: executor
        )
    }

    private static func run(
        _ source: String,
        timeout: TimeInterval,
        gate: AppleEventExecutionGate,
        executor: @escaping @Sendable (String) -> Result<String, Failure>
    ) async -> Result<String, Failure> {
        guard !Task.isCancelled else {
            return cancelledResult
        }
        guard gate.tryAcquire() else {
            return .failure(Failure(
                message: "A Notes AppleScript or Automation permission check is already executing. Wait for it to finish before retrying."
            ))
        }

        guard !Task.isCancelled else {
            gate.release()
            return cancelledResult
        }

        let cancellationRelay = AppleScriptCancellationRelay()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let box = CompletionBox(continuation)
                let shouldDispatch = cancellationRelay.install {
                    box.finish(cancelledResult)
                }
                guard shouldDispatch else {
                    gate.release()
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    guard box.beginExecution() else {
                        gate.release()
                        return
                    }

                    let result = executor(source)
                    // A timed-out/cancelled in-process NSAppleScript cannot be killed safely. Keep
                    // the singleton gate held until it really returns, then release it even though
                    // the caller's continuation may already be complete.
                    gate.release()
                    box.finish(result)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
                    box.finish(.failure(Failure(message: "AppleScript timed out after \(Int(timeout))s. The target app did not answer its Apple Event interface.")))
                }
            }
        } onCancel: {
            cancellationRelay.cancel()
        }
    }

    private static var cancelledResult: Result<String, Failure> {
        .failure(Failure(message: "AppleScript request was cancelled."))
    }

    private static func execute(_ source: String) -> Result<String, Failure> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(Failure(message: "Could not compile AppleScript."))
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            return .failure(Failure(message: message))
        }

        return .success(descriptor.stringValue ?? descriptor.description)
    }

    private static let nativeExecutor: @Sendable (String) -> Result<String, Failure> = { source in
        execute(source)
    }
}

/// A process-wide single-flight gate for synchronous in-process Apple Event operations.
///
/// `NSAppleScript.executeAndReturnError` and `AEDeterminePermissionToAutomateTarget` have no safe
/// cancellation primitive. Retaining this shared gate until the native call actually returns
/// ensures a malicious or wedged target can consume at most one such worker process-wide instead of
/// leaking a new blocked worker for every timed-out request.
final class AppleEventExecutionGate: @unchecked Sendable {
    static let shared = AppleEventExecutionGate()

    private let lock = NSLock()
    private var busy = false

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    func release() {
        lock.lock()
        busy = false
        lock.unlock()
    }
}

/// Delivers structured-concurrency cancellation across the race where the continuation has not yet
/// been installed. The installed action is invoked at most once.
private final class AppleScriptCancellationRelay: @unchecked Sendable {
    typealias Action = @Sendable () -> Void

    private enum State {
        case awaitingAction
        case armed(Action)
        case cancellationPending
        case terminal
    }

    private let lock = NSLock()
    private var state = State.awaitingAction

    func install(_ action: @escaping Action) -> Bool {
        let shouldRun: Bool
        let shouldDispatch: Bool

        lock.lock()
        switch state {
        case .awaitingAction:
            state = .armed(action)
            shouldRun = false
            shouldDispatch = true
        case .cancellationPending:
            state = .terminal
            shouldRun = true
            shouldDispatch = false
        case .armed, .terminal:
            shouldRun = false
            shouldDispatch = false
        }
        lock.unlock()

        if shouldRun {
            action()
        }
        return shouldDispatch
    }

    func cancel() {
        let action: Action?

        lock.lock()
        switch state {
        case .awaitingAction:
            state = .cancellationPending
            action = nil
        case .armed(let armedAction):
            state = .terminal
            action = armedAction
        case .cancellationPending, .terminal:
            action = nil
        }
        lock.unlock()

        action?()
    }
}
