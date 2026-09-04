import AppKit
import CoreServices
import Foundation

enum AutomationPermission {
    private static let determinationTimeout: TimeInterval = 30

    struct Status: Equatable, Sendable {
        let state: String
        let message: String?
        let osStatus: OSStatus?

        init(state: String, message: String?, osStatus: OSStatus? = nil) {
            self.state = state
            self.message = message
            self.osStatus = osStatus
        }

        var isAuthorized: Bool {
            state == "authorized"
        }

        var targetIsNotRunning: Bool {
            state == "error" && osStatus == OSStatus(procNotFound)
        }
    }

    enum HiddenLaunchResult: Equatable, Sendable {
        case launched
        case cancelled
        case failed(String)
    }

    enum NotesPreflightPurpose: Sendable {
        case status
        case permissionRequest
        case toolExecution

        var prompt: Bool {
            self == .permissionRequest
        }

        var launchIfNeeded: Bool {
            self != .status
        }
    }

    @MainActor
    static func notes(prompt: Bool) async -> Status {
        await app(
            bundleIdentifier: "com.apple.Notes",
            purpose: prompt ? .permissionRequest : .status
        )
    }

    /// A direct Notes tool call is explicit authority to start Notes hidden, but never to display a
    /// TCC prompt. `AEDeterminePermissionToAutomateTarget` returns procNotFound while an already-
    /// authorized target is closed, so execution preflight must be allowed to launch and retry.
    @MainActor
    static func notesForToolExecution() async -> Status {
        await app(bundleIdentifier: "com.apple.Notes", purpose: .toolExecution)
    }

    @MainActor
    private static func app(bundleIdentifier: String, purpose: NotesPreflightPurpose) async -> Status {
        guard !Task.isCancelled else {
            return cancelledStatus
        }
        if purpose.prompt {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        return await resolvePreflight(
            prompt: purpose.prompt,
            launchIfNeeded: purpose.launchIfNeeded,
            determine: { requestedPrompt in
                await determine(bundleIdentifier: bundleIdentifier, prompt: requestedPrompt)
            },
            launchHidden: {
                await launchApplicationHidden(bundleIdentifier: bundleIdentifier)
            },
            retryDelay: waitForLaunchReadiness
        )
    }

    /// Deterministic injection seam for tests. Callers can prove whether a status-only check or a
    /// cancelled tool preflight would cross the application-launch boundary without touching TCC
    /// or Notes.app.
    @MainActor
    static func resolvePreflightForTesting(
        purpose: NotesPreflightPurpose,
        determine: @escaping @Sendable (Bool) async -> Status,
        launchHidden: @escaping @MainActor () async -> HiddenLaunchResult
    ) async -> Status {
        await resolvePreflight(
            prompt: purpose.prompt,
            launchIfNeeded: purpose.launchIfNeeded,
            determine: determine,
            launchHidden: launchHidden,
            retryDelay: { !Task.isCancelled },
            retryAttempts: 2
        )
    }

    @MainActor
    private static func resolvePreflight(
        prompt: Bool,
        launchIfNeeded: Bool,
        determine: @escaping @Sendable (Bool) async -> Status,
        launchHidden: @escaping @MainActor () async -> HiddenLaunchResult,
        retryDelay: @escaping @MainActor () async -> Bool,
        retryAttempts: Int = 6
    ) async -> Status {
        guard !Task.isCancelled else { return cancelledStatus }

        let first = await determine(prompt)
        guard !Task.isCancelled, first.state != "cancelled" else {
            return cancelledStatus
        }
        guard launchIfNeeded,
              !Task.isCancelled,
              first.targetIsNotRunning else {
            return first
        }

        // Re-check at the side-effect boundary. The launcher repeats this check immediately before
        // asking Launch Services to start Notes.
        guard !Task.isCancelled else { return cancelledStatus }
        switch await launchHidden() {
        case .launched:
            break
        case .cancelled:
            return cancelledStatus
        case .failed(let message):
            return Status(state: "error", message: message)
        }

        guard !Task.isCancelled else { return cancelledStatus }

        // Launch Services completion can precede Apple Event registration by a short interval.
        // Retry only the non-running state, with a cancellation-aware delay and a hard bound.
        var latest = first
        for attempt in 0..<max(1, retryAttempts) {
            if attempt > 0 {
                guard await retryDelay(), !Task.isCancelled else { return cancelledStatus }
            }
            guard !Task.isCancelled else { return cancelledStatus }
            latest = await determine(prompt)
            guard !Task.isCancelled, latest.state != "cancelled" else {
                return cancelledStatus
            }
            if !latest.targetIsNotRunning {
                return latest
            }
        }
        return latest
    }

    @MainActor
    private static func launchApplicationHidden(bundleIdentifier: String) async -> HiddenLaunchResult {
        guard !Task.isCancelled else { return .cancelled }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return .failed("The target application could not be located.")
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        let waiter = HiddenLaunchWaiter()

        // Keep the cancellation check adjacent to the Launch Services call. Once this call begins,
        // cancellation cannot undo a launch already accepted by the operating system.
        guard !Task.isCancelled else { return .cancelled }
        NSWorkspace.shared.openApplication(at: url, configuration: config) { application, error in
            if let error {
                waiter.finish(.failed("Could not start the target application: \(error.localizedDescription)"))
            } else if application == nil {
                waiter.finish(.failed("Could not start the target application."))
            } else {
                waiter.finish(.launched)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            waiter.finish(.failed("Timed out while starting the target application."))
        }

        return await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            waiter.finish(.cancelled)
        }
    }

    @MainActor
    private static func waitForLaunchReadiness() async -> Bool {
        do {
            try await Task.sleep(nanoseconds: 200_000_000)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private static var cancelledStatus: Status {
        Status(state: "cancelled", message: "Automation permission check was cancelled.")
    }

    private static func determine(bundleIdentifier: String, prompt: Bool) async -> Status {
        await runDetermination(
            prompt: prompt,
            timeout: determinationTimeout,
            gate: .shared
        ) { requestedPrompt in
            determineSynchronously(
                bundleIdentifier: bundleIdentifier,
                prompt: requestedPrompt
            )
        }
    }

    /// Deterministic seam for proving the native-call isolation contract without touching TCC.
    /// The supplied executor is always dispatched to a background queue after acquiring `gate`.
    static func runDeterminationForTesting(
        prompt: Bool,
        timeout: TimeInterval,
        gate: AppleEventExecutionGate,
        executor: @escaping @Sendable (Bool) -> Status
    ) async -> Status {
        await runDetermination(
            prompt: prompt,
            timeout: timeout,
            gate: gate,
            executor: executor
        )
    }

    private static func runDetermination(
        prompt: Bool,
        timeout: TimeInterval,
        gate: AppleEventExecutionGate,
        executor: @escaping @Sendable (Bool) -> Status
    ) async -> Status {
        guard !Task.isCancelled else { return cancelledStatus }
        guard gate.tryAcquire() else {
            return Status(
                state: "busy",
                message: "Another synchronous Apple Event operation is already running. Wait for it to finish before retrying."
            )
        }

        guard !Task.isCancelled else {
            gate.release()
            return cancelledStatus
        }

        let cancellationRelay = AutomationDeterminationCancellationRelay()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let box = AutomationDeterminationCompletionBox(continuation)
                let shouldDispatch = cancellationRelay.install {
                    box.finish(cancelledStatus)
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

                    let result = executor(prompt)
                    // The API has no cancellation primitive and Apple documents that it can take
                    // arbitrarily long. Keep admission until the native call really ends, even if
                    // its caller has already cancelled or timed out.
                    gate.release()
                    box.finish(result)
                }

                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + max(0, timeout)
                ) {
                    box.finish(Status(
                        state: "timed_out",
                        message: "Automation permission check timed out after \(Int(timeout))s. The system-owned operation may still be running."
                    ))
                }
            }
        } onCancel: {
            cancellationRelay.cancel()
        }
    }

    private static func determineSynchronously(bundleIdentifier: String, prompt: Bool) -> Status {
        guard let data = bundleIdentifier.data(using: .utf8) else {
            return Status(state: "error", message: "Invalid target bundle identifier.")
        }

        var target = AEAddressDesc()
        let createStatus = data.withUnsafeBytes { bytes in
            AECreateDesc(
                typeApplicationBundleID,
                bytes.baseAddress,
                data.count,
                &target
            )
        }

        guard createStatus == noErr else {
            return Status(
                state: "error",
                message: osStatusMessage(OSStatus(createStatus)),
                osStatus: OSStatus(createStatus)
            )
        }

        defer {
            AEDisposeDesc(&target)
        }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(kCoreEventClass),
            AEEventID(kAEGetData),
            prompt
        )

        switch status {
        case noErr:
            return Status(state: "authorized", message: nil, osStatus: status)
        case OSStatus(errAEEventWouldRequireUserConsent):
            return Status(
                state: "not_determined",
                message: "Automation approval is required.",
                osStatus: status
            )
        case OSStatus(errAEEventNotPermitted):
            return Status(
                state: "denied",
                message: "Automation approval was denied or is blocked by policy.",
                osStatus: status
            )
        case OSStatus(userCanceledErr):
            return Status(
                state: "denied",
                message: "Automation approval was cancelled.",
                osStatus: status
            )
        default:
            return Status(state: "error", message: osStatusMessage(status), osStatus: status)
        }
    }

    private static func osStatusMessage(_ status: OSStatus) -> String {
        let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        return "\(error.localizedDescription) (OSStatus \(status))"
    }
}

private final class AutomationDeterminationCompletionBox: @unchecked Sendable {
    private enum State {
        case awaitingExecution
        case executing
        case completed
    }

    private let lock = NSLock()
    private var state = State.awaitingExecution
    private let continuation: CheckedContinuation<AutomationPermission.Status, Never>

    init(_ continuation: CheckedContinuation<AutomationPermission.Status, Never>) {
        self.continuation = continuation
    }

    func beginExecution() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .awaitingExecution = state else { return false }
        state = .executing
        return true
    }

    func finish(_ result: AutomationPermission.Status) {
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

/// Bridges task cancellation across continuation installation without trying to terminate the
/// underlying Apple Event operation. The installed action is invoked at most once.
private final class AutomationDeterminationCancellationRelay: @unchecked Sendable {
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

        if shouldRun { action() }
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

private final class HiddenLaunchWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AutomationPermission.HiddenLaunchResult?
    private var continuation: CheckedContinuation<AutomationPermission.HiddenLaunchResult, Never>?

    func wait() async -> AutomationPermission.HiddenLaunchResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: AutomationPermission.HiddenLaunchResult) {
        let continuation: CheckedContinuation<AutomationPermission.HiddenLaunchResult, Never>?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
