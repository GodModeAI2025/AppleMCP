import AVFoundation
import Foundation
import M3MCPCore
import Speech

/// `SFSpeechRecognizer` transcription, used where the macOS 26 speech stack is unavailable.
///
/// `SpeechTranscription` is the preferred path: it drives `SpeechAnalyzer`, the same engine Voice
/// Memos itself uses. This one keeps transcription working on macOS 15 to 25, where that stack does
/// not exist. Both run inside M3MCPApp, so macOS attributes the Speech Recognition permission to the
/// signed app bundle rather than to the MCP bridge process.
///
/// Named to stay clear of `Speech.SpeechTranscriber`, the macOS 26 type the other path uses.
enum LegacySpeechRecognizer {
    private static let operationAdmission = AsyncOperationAdmission(
        maximumConcurrentOperations: 1
    )

    struct Result: Sendable {
        let text: String
        let segments: [VoiceMemoTranscript.Segment]
        let locale: String
        /// A legacy result can exist only after the strict local-capability preflight and a request
        /// with `requiresOnDeviceRecognition = true`; make a contradictory result unrepresentable.
        var onDevice: Bool { true }
    }

    struct Failure: Error, LocalizedError, Sendable {
        let state: String
        let message: String

        init(state: String, message: String) {
            self.state = state
            self.message = message
        }

        var errorDescription: String? { message }
    }

    /// Current Speech Recognition permission state, optionally triggering the system prompt.
    static func authorizationState(prompt: Bool) async -> String {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard prompt, status == .notDetermined else {
            return state(for: status)
        }

        do {
            let updated: SFSpeechRecognizerAuthorizationStatus = try await awaitCancellableCallback { completion in
                SFSpeechRecognizer.requestAuthorization { completion(.success($0)) }
            }
            return state(for: updated)
        } catch is CancellationError {
            return "cancelled"
        } catch {
            return "error"
        }
    }

    static func transcribe(
        input: VerifiedVoiceMemoAudioInput,
        languageCode: String,
        budget: VoiceMemoTranscriptionBudget
    ) async throws -> Result {
        // Authorization/capability checks and AVAsset metadata loading are part of the same
        // absolute whole-tool deadline. A native preflight that ignores cancellation retains this
        // admission lease until it really exits, while the caller still receives a prompt timeout.
        do {
            return try await runBudgetedOperation(
                budget: budget,
                admission: operationAdmission
            ) {
                try await transcribeWithoutDeadline(
                    input: input,
                    languageCode: languageCode,
                    budget: budget
                )
            }
        } catch is AsyncOperationDeadline.TimedOut {
            throw timeoutFailure(for: budget)
        } catch let busy as AsyncOperationDeadline.ResourceBusy {
            throw Failure(
                state: "resource_busy",
                message: "Another legacy on-device speech operation is still active or finishing "
                    + "after cancellation (limit \(busy.maximumConcurrentOperations)). Retry after it has stopped."
            )
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    /// Injectable seam that proves the legacy preflight and recognition share the same resource-
    /// bounded absolute deadline without requiring Speech permission or user recordings in tests.
    static func runBudgetedOperation<Value: Sendable>(
        budget: VoiceMemoTranscriptionBudget,
        admission: AsyncOperationAdmission,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        return try await AsyncOperationDeadline.run(
            budget: budget,
            admission: admission,
            operation: operation
        )
    }

    private static func transcribeWithoutDeadline(
        input: VerifiedVoiceMemoAudioInput,
        languageCode: String,
        budget: VoiceMemoTranscriptionBudget
    ) async throws -> Result {
        // AVURLAsset refers to `/dev/fd/N`; retain its owning object until both feeder and Speech
        // framework state have drained, even after the caller-facing deadline has already fired.
        defer { withExtendedLifetime(input) {} }

        // A transcription request must not be able to raise a TCC prompt from the default-safe
        // tool catalog. Permission UI is an independent, launch-time opt-in; preflight here and
        // direct the user to that explicit path when Speech Recognition has not been granted yet.
        let permission = await authorizationState(prompt: false)
        guard permission == "authorized" else {
            throw Failure(
                state: permission,
                message: "Speech Recognition is not authorized for M3MCP. Run permissions_request, or grant access in System Settings > Privacy & Security > Speech Recognition."
            )
        }

        let locale = Locale(identifier: languageCode)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw Failure(state: "unavailable", message: "No speech recognizer exists for locale \(languageCode).")
        }

        guard recognizer.isAvailable else {
            throw Failure(
                state: "unavailable",
                message: "The speech recognizer for \(languageCode) is not available. Install the language in System Settings > Accessibility > Voice Control, then retry."
            )
        }

        // `SFSpeechRecognizer` may send audio to Apple when this capability is false. Reject the
        // operation before constructing or starting a recognition task; privacy must not depend on
        // a best-effort request preference.
        guard OnDeviceSpeechPolicy.permitsRecognition(
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        ) else {
            throw Failure(
                state: "on_device_unavailable",
                message: OnDeviceSpeechPolicy.unsupportedMessage
            )
        }

        let decoder: BoundedLegacyAudioDecoder
        do {
            decoder = try await BoundedLegacyAudioDecoder.make(
                url: input.url,
                mimeType: input.mimeType
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure(
                state: "unsupported_audio",
                message: "Could not prepare the verified recording for on-device recognition: "
                    + error.localizedDescription
            )
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = true

        // Authorization and capability preflight consume the same whole-tool budget. Starting a
        // fresh relative timeout here would let analyzer + fallback exceed the bridge window.
        let timeout = budget.remainingSeconds()
        guard timeout > 0 else {
            throw timeoutFailure(for: budget)
        }

        let gate = SingleUseGate()
        let taskBox = RecognitionTaskBox<SFSpeechRecognitionTask>()
        let cancellationRelay = RecognitionCancellationRelay()
        let feedBox = LegacyAudioFeedBox(decoder: decoder)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                let finishAfterDrain: @Sendable (Swift.Result<Result, Error>) -> Void = { outcome in
                    feedBox.cancel()
                    Task.detached {
                        await waitForSessionDrain(
                            feederDone: { await feedBox.waitUntilFinished() },
                            recognitionDone: { await taskBox.waitUntilCompleted() }
                        )
                        continuation.resume(with: outcome)
                    }
                }
                let timeoutTimer = CancellableDeadlineTimer()
                let timeoutAction: @Sendable () -> Void = {
                    guard gate.claim() else { return }
                    cancellationRelay.finish()
                    taskBox.cancel()
                    finishAfterDrain(.failure(timeoutFailure(for: budget)))
                }

                let shouldStartRecognition = cancellationRelay.install {
                    guard gate.claim() else { return }
                    timeoutTimer.cancel()
                    taskBox.cancel()
                    finishAfterDrain(.failure(CancellationError()))
                }
                guard shouldStartRecognition else {
                    // Cancellation won before recognition-task construction. Tell the drain that
                    // no framework task can now be installed, otherwise it would correctly wait
                    // forever for a task that this branch deliberately never creates.
                    taskBox.markNoTaskWillBeInstalled()
                    return
                }

                // Unlike a cancelled `DispatchWorkItem` submitted through `asyncAfter`, this
                // timer drops its action immediately on cancellation instead of retaining the
                // entire native session until a deadline that can be 30 minutes away.
                guard timeoutTimer.arm(after: timeout, action: timeoutAction) else {
                    // Structured cancellation can win after relay installation but before the
                    // timer is armed. In that ordering no Speech task will be constructed.
                    taskBox.markNoTaskWillBeInstalled()
                    return
                }

                let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        guard gate.claim() else { return }
                        cancellationRelay.finish()
                        timeoutTimer.cancel()
                        // A timer event may itself run late. An error callback that arrives after
                        // the absolute deadline must not beat that delayed timer and extend the
                        // tool call beyond its documented whole-pipeline budget.
                        guard budget.permitsCompletion() else {
                            taskBox.cancel()
                            finishAfterDrain(.failure(timeoutFailure(for: budget)))
                            return
                        }
                        finishAfterDrain(
                            .failure(
                                Failure(
                                    state: "error",
                                    message: error.localizedDescription
                                )
                            )
                        )
                        return
                    }

                    guard let result, result.isFinal else { return }
                    guard gate.claim() else { return }
                    cancellationRelay.finish()
                    timeoutTimer.cancel()
                    guard budget.permitsCompletion() else {
                        taskBox.cancel()
                        finishAfterDrain(.failure(timeoutFailure(for: budget)))
                        return
                    }

                    let segments = result.bestTranscription.segments.map { segment in
                        VoiceMemoTranscript.Segment(
                            text: segment.substring,
                            start: segment.timestamp,
                            end: segment.timestamp + segment.duration
                        )
                    }

                    // Segment materialization is normally tiny, but the absolute deadline still
                    // governs the value actually published to the bridge.
                    guard budget.permitsCompletion() else {
                        taskBox.cancel()
                        finishAfterDrain(.failure(timeoutFailure(for: budget)))
                        return
                    }

                    finishAfterDrain(
                        .success(
                            Result(
                            text: result.bestTranscription.formattedString,
                            segments: segments,
                            locale: locale.identifier
                            )
                        )
                    )
                }
                taskBox.install(recognitionTask)

                // Feed the Speech request from bounded AVAssetReader PCM in this process. The
                // source is the provider's retained descriptor URL; no mutable library pathname is
                // forwarded to the Speech service.
                feedBox.start {
                    do {
                        try await SerializedLegacyAudioFeed.run(
                            next: { try decoder.next() },
                            permitsCompletion: { budget.permitsCompletion() },
                            deadlineError: { timeoutFailure(for: budget) },
                            append: { request.append($0) },
                            endAudio: { request.endAudio() }
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        guard gate.claim() else {
                            return
                        }
                        cancellationRelay.finish()
                        timeoutTimer.cancel()
                        taskBox.cancel()
                        if let failure = error as? Failure {
                            finishAfterDrain(.failure(failure))
                        } else {
                            finishAfterDrain(
                                .failure(
                                    Failure(
                                    state: "unsupported_audio",
                                    message: "Could not decode the verified recording for "
                                        + "on-device recognition: \(error.localizedDescription)"
                                    )
                                )
                            )
                        }
                    }
                }
            }
        } onCancel: {
            cancellationRelay.cancel()
        }
    }

    private static func timeoutFailure(for budget: VoiceMemoTranscriptionBudget) -> Failure {
        Failure(
            state: "timeout",
            message: "Speech recognition did not finish within "
                + "\(Int(budget.requestedSeconds.rounded(.up))) seconds."
        )
    }

    /// Waits for both pieces of native work that can survive Swift-task cancellation. This helper
    /// is also the deterministic test seam for the admission-lifetime contract.
    static func waitForSessionDrain(
        feederDone: @escaping @Sendable () async -> Void,
        recognitionDone: @escaping @Sendable () async -> Void
    ) async {
        async let feeder: Void = feederDone()
        async let recognition: Void = recognitionDone()
        _ = await (feeder, recognition)
    }

    private static func state(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "not_determined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
}

/// Runs all mutations of `SFSpeechAudioBufferRecognitionRequest` on the feeder task. Cancellation
/// can be requested concurrently, but `endAudio` is reached by stack unwinding on this same task,
/// after any in-progress `append` has returned.
enum SerializedLegacyAudioFeed {
    static func run<Element>(
        next: () throws -> Element?,
        permitsCompletion: () -> Bool,
        deadlineError: () -> Error,
        append: (Element) -> Void,
        endAudio: () -> Void
    ) async throws {
        defer { endAudio() }

        while let element = try next() {
            try Task.checkCancellation()
            guard permitsCompletion() else {
                throw deadlineError()
            }
            append(element)
            await Task.yield()
        }
    }
}

/// Owns the bounded legacy PCM feeder and prevents it from entering AVAssetReader before its task
/// reference is installed. Timeout/cancellation can therefore stop a feeder that races startup.
private final class LegacyAudioFeedBox: @unchecked Sendable {
    private enum State {
        case awaitingTask
        case active(Task<Void, Never>)
        case cancelling(Task<Void, Never>)
        case terminal
    }

    private let decoder: BoundedLegacyAudioDecoder
    private let lock = NSLock()
    private var state = State.awaitingTask
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(decoder: BoundedLegacyAudioDecoder) {
        self.decoder = decoder
    }

    func start(_ operation: @escaping @Sendable () async -> Void) {
        let latch = LegacyAudioFeedStartLatch()
        let task = Task.detached(priority: .userInitiated) { [self] in
            defer { finish() }
            guard await latch.waitForPermission(), !Task.isCancelled else { return }
            await operation()
        }

        let allowStart: Bool
        lock.lock()
        switch state {
        case .awaitingTask:
            state = .active(task)
            allowStart = true
        case .active, .cancelling, .terminal:
            allowStart = false
        }
        lock.unlock()

        if !allowStart { task.cancel() }
        latch.resolve(allowStart: allowStart)
    }

    func cancel() {
        let task: Task<Void, Never>?
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        switch state {
        case .awaitingTask:
            state = .terminal
            task = nil
            waiters = completionWaiters
            completionWaiters.removeAll()
        case .active(let activeTask):
            state = .cancelling(activeTask)
            task = activeTask
            waiters = []
        case .cancelling:
            task = nil
            waiters = []
        case .terminal:
            task = nil
            waiters = []
        }
        lock.unlock()

        decoder.cancel()
        task?.cancel()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func finish() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        if case .terminal = state {
            waiters = []
        } else {
            state = .terminal
            waiters = completionWaiters
            completionWaiters.removeAll()
        }
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            let finished: Bool
            lock.lock()
            if case .terminal = state {
                finished = true
            } else {
                completionWaiters.append(continuation)
                finished = false
            }
            lock.unlock()

            if finished {
                continuation.resume()
            }
        }
    }
}

private final class LegacyAudioFeedStartLatch: @unchecked Sendable {
    private enum State {
        case waiting
        case suspended(CheckedContinuation<Bool, Never>)
        case resolved(Bool)
    }

    private let lock = NSLock()
    private var state = State.waiting

    func waitForPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case .waiting:
                state = .suspended(continuation)
                lock.unlock()
            case .resolved(let allowStart):
                lock.unlock()
                continuation.resume(returning: allowStart)
            case .suspended:
                lock.unlock()
                preconditionFailure("Legacy audio feed latch awaited more than once")
            }
        }
    }

    func resolve(allowStart: Bool) {
        let continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        switch state {
        case .waiting:
            state = .resolved(allowStart)
            continuation = nil
        case .suspended(let suspended):
            state = .resolved(allowStart)
            continuation = suspended
        case .resolved:
            lock.unlock()
            return
        }
        lock.unlock()
        continuation?.resume(returning: allowStart)
    }
}

/// Guards a continuation so the recognition callback and the timeout cannot both resume it.
private final class SingleUseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used {
            return false
        }
        used = true
        return true
    }
}

/// One-shot deadline whose retained action is released synchronously by `cancel()` or `fire()`.
///
/// `DispatchQueue.asyncAfter` retains a submitted work item's captures until its deadline even
/// after `DispatchWorkItem.cancel()` is called. Legacy recognition allows a deadline of up to 30
/// minutes, so cancellation must own and clear the action independently of the dispatch queue.
/// The timer's event handler captures only this owner weakly; the potentially large recognition
/// session graph lives solely in `state` and is therefore released as soon as either terminal path
/// wins the lock.
final class CancellableDeadlineTimer: @unchecked Sendable {
    private typealias Action = @Sendable () -> Void

    private enum State {
        case idle
        case armed(Action)
        case terminal
    }

    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var state = State.idle

    init(queue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [weak self] in
            self?.fire()
        }
        // Activating an unscheduled timer is valid; it remains dormant until `arm` supplies its
        // sole deadline. This also makes cancellation-before-arm safe and deterministic.
        timer.activate()
    }

    /// Arms the one-shot timer exactly once. Returns `false` if cancellation already won.
    @discardableResult
    func arm(after seconds: TimeInterval, action: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard case .idle = state else {
            lock.unlock()
            return false
        }
        state = .armed(action)
        timer.schedule(deadline: .now() + max(0, seconds), repeating: .never)
        lock.unlock()
        return true
    }

    func cancel() {
        let shouldCancel: Bool

        lock.lock()
        switch state {
        case .idle, .armed:
            // Overwriting `.armed` releases the action and all of its captures synchronously.
            state = .terminal
            shouldCancel = true
        case .terminal:
            shouldCancel = false
        }
        lock.unlock()

        if shouldCancel {
            timer.cancel()
        }
    }

    private func fire() {
        let action: Action?

        lock.lock()
        switch state {
        case .armed(let armedAction):
            state = .terminal
            action = armedAction
        case .idle, .terminal:
            action = nil
        }
        lock.unlock()

        // Cancel the one-shot source before invoking user code. A concurrent `cancel()` either
        // cleared the action first or observes `.terminal`; the action can therefore run once at
        // most and is no longer retained by this object while it executes.
        timer.cancel()
        action?()
    }

    deinit {
        timer.cancel()
    }
}

/// Relays structured-concurrency cancellation into a continuation that may not exist yet.
///
/// Cancellation can race between `Task.checkCancellation()` and continuation setup. Remembering a
/// pending cancellation makes that ordering equivalent to cancellation after setup: the installed
/// action runs exactly once and the framework operation is never started. `finish()` drops the
/// action when a callback or timeout wins first, avoiding any late continuation access.
final class RecognitionCancellationRelay: @unchecked Sendable {
    private typealias Action = @Sendable () -> Void

    private enum State {
        case awaitingAction
        case armed(Action)
        case cancellationPending
        case terminal
    }

    private let lock = NSLock()
    private var state = State.awaitingAction

    /// Arms cancellation before any framework task can be created. Returns `false` when a pending
    /// cancellation was delivered immediately or another terminal event already won.
    func install(_ action: @escaping @Sendable () -> Void) -> Bool {
        let shouldRun: Bool
        let shouldStart: Bool

        lock.lock()
        switch state {
        case .awaitingAction:
            state = .armed(action)
            shouldRun = false
            shouldStart = true
        case .cancellationPending:
            state = .terminal
            shouldRun = true
            shouldStart = false
        case .armed, .terminal:
            shouldRun = false
            shouldStart = false
        }
        lock.unlock()

        if shouldRun {
            action()
        }
        return shouldStart
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

    func finish() {
        lock.lock()
        state = .terminal
        lock.unlock()
    }
}

protocol RecognitionTaskCancelling: AnyObject {
    func cancel()
    /// `true` only for the framework's actual terminal state. A cancellation request or an
    /// intermediate `.canceling` state is deliberately insufficient to release admission.
    var hasCompletedRecognition: Bool { get }
}

extension SFSpeechRecognitionTask: RecognitionTaskCancelling {
    var hasCompletedRecognition: Bool { state == .completed }
}

/// Synchronizes a recognition task with timeout, callback completion, and structured-concurrency
/// cancellation. A terminal event that wins before `install` is remembered so a late task cannot
/// escape cancellation and continue processing audio in the background.
final class RecognitionTaskBox<TaskType: RecognitionTaskCancelling>: @unchecked Sendable {
    private enum State {
        case awaitingTask(cancelRequested: Bool)
        case active(TaskType, cancelRequested: Bool)
        case noTask
        case completed
    }

    private let lock = NSLock()
    private var state = State.awaitingTask(cancelRequested: false)

    func install(_ task: TaskType) {
        let shouldCancel: Bool

        lock.lock()
        switch state {
        case .awaitingTask(let cancelRequested):
            state = .active(task, cancelRequested: cancelRequested)
            shouldCancel = cancelRequested
        case .active, .noTask, .completed:
            // There is only one recognition task per box. Treat a duplicate or late install as a
            // task that must not outlive the operation.
            shouldCancel = true
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task: TaskType?

        lock.lock()
        switch state {
        case .awaitingTask(cancelRequested: false):
            state = .awaitingTask(cancelRequested: true)
            task = nil
        case .awaitingTask(cancelRequested: true):
            task = nil
        case .active(let activeTask, cancelRequested: false):
            state = .active(activeTask, cancelRequested: true)
            task = activeTask
        case .active(_, cancelRequested: true), .noTask, .completed:
            task = nil
        }
        lock.unlock()

        // Do not invoke framework code under the lock: `cancel()` may synchronously trigger the
        // recognition callback, which starts the asynchronous drain observer.
        task?.cancel()
    }

    /// Completes an install waiter only for the one branch that exits before constructing a Speech
    /// task. Once a task exists, even a callback cannot substitute for observing `.completed`.
    func markNoTaskWillBeInstalled() {
        lock.lock()
        if case .awaitingTask = state {
            state = .noTask
        }
        lock.unlock()
    }

    func waitUntilCompleted(pollIntervalNanoseconds: UInt64 = 10_000_000) async {
        while true {
            switch completionObservation() {
            case .finished:
                return
            case .active(let activeTask):
                if activeTask.hasCompletedRecognition {
                    markCompletedIfActive()
                    return
                }
            case .waitingForInstallation:
                break
            }

            // This method runs in the detached drain task, which is intentionally never cancelled.
            // Polling is serialized and bounded to one live legacy operation by admission.
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    private enum CompletionObservation {
        case waitingForInstallation
        case active(TaskType)
        case finished
    }

    private func completionObservation() -> CompletionObservation {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .awaitingTask:
            return .waitingForInstallation
        case .active(let task, _):
            return .active(task)
        case .noTask, .completed:
            return .finished
        }
    }

    private func markCompletedIfActive() {
        lock.lock()
        if case .active = state {
            state = .completed
        }
        lock.unlock()
    }
}
