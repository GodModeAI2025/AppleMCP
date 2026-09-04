import Foundation

/// Pure policy shared by the app and its tests.
///
/// The legacy Speech framework may use Apple's servers unless the recognizer supports and the
/// request requires on-device recognition. M3MCP never permits that fallback for Voice Memos.
public enum OnDeviceSpeechPolicy {
    public static let unsupportedMessage = "On-device speech recognition is unavailable for this locale. M3MCP did not submit the recording for recognition because cloud speech processing is disabled. Install the language in System Settings > Accessibility > Voice Control, then retry."

    public static func permitsRecognition(supportsOnDeviceRecognition: Bool) -> Bool {
        supportsOnDeviceRecognition
    }
}

/// One timeout contract shared by Voice Memos providers, MCP schema documentation, and the local
/// bridge transport. The transport must remain alive after the longest provider deadline so the app
/// can serialize and return the provider's timeout result instead of being misreported as unreachable.
public enum VoiceMemoTranscriptionTimeoutPolicy {
    public static let minimumSeconds = 10
    public static let defaultSeconds = 300
    public static let maximumSeconds = 1_800
    public static let transportResponseOverheadSeconds = 30
    public static let transportResponseTimeoutSeconds =
        maximumSeconds + transportResponseOverheadSeconds

    public static func validatedProviderSeconds(_ requestedSeconds: Int) -> Int? {
        guard (minimumSeconds ... maximumSeconds).contains(requestedSeconds) else {
            return nil
        }
        return requestedSeconds
    }
}

/// One absolute monotonic budget shared by every recognition stage in a Voice Memo tool call.
///
/// Stages receive only the remaining duration. An eligible analyzer failure therefore cannot grant
/// the legacy recognizer a second full timeout and overrun the bridge's response window.
public struct VoiceMemoTranscriptionBudget: Sendable {
    public let requestedSeconds: TimeInterval
    fileprivate let deadlineNanoseconds: UInt64

    public init(
        seconds: TimeInterval,
        startNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        requestedSeconds = seconds.isNaN ? 0 : max(0, seconds)
        let scaled = requestedSeconds * 1_000_000_000
        let duration: UInt64
        if !scaled.isFinite || scaled >= Double(UInt64.max) {
            duration = UInt64.max
        } else {
            duration = UInt64(scaled.rounded(.up))
        }
        let addition = startNanoseconds.addingReportingOverflow(duration)
        deadlineNanoseconds = addition.overflow ? UInt64.max : addition.partialValue
    }

    public func remainingSeconds(
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> TimeInterval {
        guard nowNanoseconds < deadlineNanoseconds else { return 0 }
        return TimeInterval(deadlineNanoseconds - nowNanoseconds) / 1_000_000_000
    }

    /// Whether a stage callback may still publish a result under the whole-tool deadline.
    ///
    /// Dispatch timers provide a not-before scheduling guarantee, not an exact firing time. Native
    /// framework callbacks must therefore consult the monotonic budget themselves before claiming
    /// success or surfacing a stage error; otherwise a late callback can beat a delayed timer.
    public func permitsCompletion(
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        remainingSeconds(nowNanoseconds: nowNanoseconds) > 0
    }
}

/// Bounds native operations that may take time to observe cooperative task cancellation.
///
/// A lease remains occupied until the operation task actually returns, not merely until its caller
/// receives a timeout or cancellation error. That distinction prevents repeated timed-out calls
/// from accumulating an unbounded number of still-running framework operations.
public final class AsyncOperationAdmission: @unchecked Sendable {
    public let maximumConcurrentOperations: Int

    private let lock = NSLock()
    private var activeOperations = 0

    public init(maximumConcurrentOperations: Int) {
        precondition(maximumConcurrentOperations > 0)
        self.maximumConcurrentOperations = maximumConcurrentOperations
    }

    public var activeOperationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeOperations
    }

    fileprivate func acquire() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard activeOperations < maximumConcurrentOperations else { return nil }
        activeOperations += 1
        return Lease(admission: self)
    }

    fileprivate func release() {
        lock.lock()
        precondition(activeOperations > 0)
        activeOperations -= 1
        lock.unlock()
    }

    fileprivate final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var admission: AsyncOperationAdmission?

        init(admission: AsyncOperationAdmission) {
            self.admission = admission
        }

        func release() {
            let claimed: AsyncOperationAdmission?
            lock.lock()
            claimed = admission
            admission = nil
            lock.unlock()
            claimed?.release()
        }

        deinit {
            release()
        }
    }
}

/// Runs an unstructured async operation against an absolute monotonic deadline.
///
/// A structured task-group race cannot return while a cancellation-ignoring child is still alive,
/// because leaving the group waits for every child. This coordinator resumes the caller as soon as
/// the deadline or caller cancellation wins, safely ignores late completion, and cancels the native
/// operation as a best effort. The required admission lease remains held until that operation truly
/// exits, so late framework work is bounded rather than accumulated by retries.
public enum AsyncOperationDeadline {
    public struct TimedOut: Error, Equatable, Sendable {
        public let seconds: TimeInterval

        public init(seconds: TimeInterval) {
            self.seconds = seconds
        }
    }

    public struct ResourceBusy: Error, Equatable, Sendable {
        public let maximumConcurrentOperations: Int

        public init(maximumConcurrentOperations: Int) {
            self.maximumConcurrentOperations = maximumConcurrentOperations
        }
    }

    public static func run<Value: Sendable>(
        seconds: TimeInterval,
        admission: AsyncOperationAdmission,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await run(
            seconds: seconds,
            admission: admission,
            beforeOperationTaskInstallation: nil,
            operation: operation
        )
    }

    /// Runs against the exact absolute deadline established at Voice Memo tool entry. Unlike
    /// reconstructing a relative timeout from a sampled remainder, this cannot add setup latency
    /// back onto the end of the whole-tool budget.
    public static func run<Value: Sendable>(
        budget: VoiceMemoTranscriptionBudget,
        admission: AsyncOperationAdmission,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await run(
            deadline: budget.deadlineNanoseconds,
            timeoutSeconds: budget.requestedSeconds,
            admission: admission,
            beforeOperationTaskInstallation: nil,
            operation: operation
        )
    }

    /// Deterministic seam for proving cancellation in the otherwise sub-microsecond interval
    /// between operation-task construction and coordinator registration.
    static func runForTesting<Value: Sendable>(
        seconds: TimeInterval,
        admission: AsyncOperationAdmission,
        beforeOperationTaskInstallation: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await run(
            seconds: seconds,
            admission: admission,
            beforeOperationTaskInstallation: beforeOperationTaskInstallation,
            operation: operation
        )
    }

    private static func run<Value: Sendable>(
        seconds: TimeInterval,
        admission: AsyncOperationAdmission,
        beforeOperationTaskInstallation: (@Sendable () -> Void)?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let duration = seconds.isNaN ? 0 : max(0, seconds)
        guard duration > 0 else {
            throw TimedOut(seconds: duration)
        }

        let nanosecondsValue = duration * 1_000_000_000
        let nanoseconds: UInt64
        if !nanosecondsValue.isFinite || nanosecondsValue >= Double(UInt64.max) {
            nanoseconds = UInt64.max
        } else {
            nanoseconds = UInt64(nanosecondsValue.rounded(.up))
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let addition = now.addingReportingOverflow(nanoseconds)
        let deadline = addition.overflow ? UInt64.max : addition.partialValue

        return try await run(
            deadline: deadline,
            timeoutSeconds: duration,
            admission: admission,
            beforeOperationTaskInstallation: beforeOperationTaskInstallation,
            operation: operation
        )
    }

    private static func run<Value: Sendable>(
        deadline: UInt64,
        timeoutSeconds: TimeInterval,
        admission: AsyncOperationAdmission,
        beforeOperationTaskInstallation: (@Sendable () -> Void)?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw TimedOut(seconds: timeoutSeconds)
        }
        let race = AsyncDeadlineRace<Value>()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                race.start(
                    continuation: continuation,
                    deadline: deadline,
                    timeoutSeconds: timeoutSeconds,
                    admission: admission,
                    beforeOperationTaskInstallation: beforeOperationTaskInstallation,
                    operation: operation
                )
            }
        } onCancel: {
            race.cancel()
        }
    }
}

private final class AsyncDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    func start(
        continuation: CheckedContinuation<Value, Error>,
        deadline: UInt64,
        timeoutSeconds: TimeInterval,
        admission: AsyncOperationAdmission,
        beforeOperationTaskInstallation: (@Sendable () -> Void)?,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        lock.lock()
        if terminal {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        guard isActive else { return }
        guard let lease = admission.acquire() else {
            finish(
                .failure(
                    AsyncOperationDeadline.ResourceBusy(
                        maximumConcurrentOperations: admission.maximumConcurrentOperations
                    )
                ),
                cancelOperation: true,
                cancelDeadline: true
            )
            return
        }

        guard isActive else {
            lease.release()
            return
        }

        let startLatch = AsyncOperationStartLatch()
        let priority = Task.currentPriority
        let operationTask = Task.detached(priority: priority) { [self] in
            guard await startLatch.waitForPermission(),
                  isActive,
                  !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadline else {
                lease.release()
                return
            }

            do {
                try Task.checkCancellation()
                let value = try await operation()
                let completedBeforeDeadline =
                    DispatchTime.now().uptimeNanoseconds < deadline
                lease.release()
                finish(
                    completedBeforeDeadline
                        ? .success(value)
                        : .failure(AsyncOperationDeadline.TimedOut(seconds: timeoutSeconds)),
                    cancelOperation: false,
                    cancelDeadline: true
                )
            } catch {
                let completedBeforeDeadline =
                    DispatchTime.now().uptimeNanoseconds < deadline
                lease.release()
                finish(
                    completedBeforeDeadline
                        ? .failure(error)
                        : .failure(AsyncOperationDeadline.TimedOut(seconds: timeoutSeconds)),
                    cancelOperation: false,
                    cancelDeadline: true
                )
            }
        }
        beforeOperationTaskInstallation?()
        let installed = installOperationTask(operationTask)
        let deadlineHasElapsed = DispatchTime.now().uptimeNanoseconds >= deadline
        if installed, deadlineHasElapsed {
            finish(
                .failure(AsyncOperationDeadline.TimedOut(seconds: timeoutSeconds)),
                cancelOperation: true,
                cancelDeadline: true
            )
        }
        // The operation closure cannot run before this point. If cancellation or timeout won while
        // the task was being registered, the latch releases it only onto the no-start cleanup path.
        startLatch.resolve(allowStart: installed && !deadlineHasElapsed && isActive)

        let deadlineTask = Task.detached(priority: priority) { [self] in
            let current = DispatchTime.now().uptimeNanoseconds
            if current < deadline {
                do {
                    try await Task.sleep(nanoseconds: deadline - current)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            finish(
                .failure(AsyncOperationDeadline.TimedOut(seconds: timeoutSeconds)),
                cancelOperation: true,
                cancelDeadline: false
            )
        }
        installDeadlineTask(deadlineTask)
    }

    func cancel() {
        finish(.failure(CancellationError()), cancelOperation: true, cancelDeadline: true)
    }

    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !terminal
    }

    private func installOperationTask(_ task: Task<Void, Never>) -> Bool {
        let shouldCancel: Bool
        lock.lock()
        if terminal {
            shouldCancel = true
        } else {
            operationTask = task
            shouldCancel = false
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
        return !shouldCancel
    }

    private func installDeadlineTask(_ task: Task<Void, Never>) {
        let shouldCancel: Bool
        lock.lock()
        if terminal {
            shouldCancel = true
        } else {
            deadlineTask = task
            shouldCancel = false
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    private func finish(
        _ result: Result<Value, Error>,
        cancelOperation: Bool,
        cancelDeadline: Bool
    ) {
        let claimedContinuation: CheckedContinuation<Value, Error>?
        let claimedOperation: Task<Void, Never>?
        let claimedDeadline: Task<Void, Never>?

        lock.lock()
        guard !terminal else {
            lock.unlock()
            return
        }
        terminal = true
        claimedContinuation = continuation
        continuation = nil
        claimedOperation = cancelOperation ? operationTask : nil
        operationTask = nil
        claimedDeadline = cancelDeadline ? deadlineTask : nil
        deadlineTask = nil
        lock.unlock()

        claimedOperation?.cancel()
        claimedDeadline?.cancel()
        claimedContinuation?.resume(with: result)
    }
}

/// One-shot async barrier that prevents an operation task from entering native code before the
/// deadline coordinator has installed the task reference cancellation needs.
private final class AsyncOperationStartLatch: @unchecked Sendable {
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
                preconditionFailure("Operation start latch awaited more than once")
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
        case .suspended(let claimed):
            state = .resolved(allowStart)
            continuation = claimed
        case .resolved:
            lock.unlock()
            return
        }
        lock.unlock()
        continuation?.resume(returning: allowStart)
    }
}

/// Fixed resource limits for the AVAssetReader fallback used by Voice Memo transcription.
///
/// The decoder normalizes fallback audio to 16 kHz mono Float32 PCM. Typical Voice Memos use
/// 44.1/48 kHz source audio; the source budget therefore accepts recordings up to two hours while
/// rejecting corrupt metadata and unusually expensive high-rate tracks before streaming starts.
public enum SpeechTranscodePolicy {
    public static let maximumSourceDurationSeconds: Double = 2 * 60 * 60
    public static let maximumEstimatedSourceFrames: UInt64 = 400_000_000
    public static let outputSampleRate: Double = 16_000
    public static let outputChannelCount = 1
    public static let maximumDecodedFrames: UInt64 = 115_200_000
    public static let maximumDecodedPCMBytes: UInt64 = 512 * 1_024 * 1_024
    public static let maximumSampleBuffers: UInt64 = 500_000

    public enum Violation: Error, Equatable, Sendable, LocalizedError {
        case invalidSourceDuration
        case sourceDurationLimit
        case invalidSourceSampleRate
        case sourceFrameLimit
        case decodedFrameLimit
        case decodedByteLimit
        case sampleBufferLimit
        case arithmeticOverflow

        public var errorDescription: String? {
            switch self {
            case .invalidSourceDuration:
                return "the audio track has an invalid or empty duration"
            case .sourceDurationLimit:
                return "the audio track exceeds the \(Int(maximumSourceDurationSeconds)) second transcode limit"
            case .invalidSourceSampleRate:
                return "the audio track has no valid sample-rate metadata"
            case .sourceFrameLimit:
                return "the audio track exceeds the \(maximumEstimatedSourceFrames) source-frame transcode limit"
            case .decodedFrameLimit:
                return "decoded audio exceeds the \(maximumDecodedFrames) frame transcode limit"
            case .decodedByteLimit:
                return "decoded audio exceeds the \(maximumDecodedPCMBytes) byte transcode limit"
            case .sampleBufferLimit:
                return "audio decoding exceeds the \(maximumSampleBuffers) sample-buffer work limit"
            case .arithmeticOverflow:
                return "audio decoding counters overflowed"
            }
        }
    }

    public static func validateSource(durationSeconds: Double, sampleRate: Double) throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw Violation.invalidSourceDuration
        }
        guard durationSeconds <= maximumSourceDurationSeconds else {
            throw Violation.sourceDurationLimit
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw Violation.invalidSourceSampleRate
        }

        let estimatedFrames = durationSeconds * sampleRate
        guard estimatedFrames.isFinite,
              estimatedFrames <= Double(maximumEstimatedSourceFrames) else {
            throw Violation.sourceFrameLimit
        }
    }

    /// Charges one decoded buffer before any narrowing integer conversion or PCM allocation.
    @discardableResult
    public static func preflightBufferAllocation(
        frameCount: Int,
        bytesPerFrame: UInt64,
        bufferCount: UInt64,
        meter: inout Meter
    ) throws -> UInt64 {
        guard frameCount > 0, bytesPerFrame > 0, bufferCount > 0 else {
            throw Violation.arithmeticOverflow
        }

        let frameBytes = UInt64(frameCount).multipliedReportingOverflow(by: bytesPerFrame)
        let decodedBytes = frameBytes.partialValue.multipliedReportingOverflow(by: bufferCount)
        guard !frameBytes.overflow, !decodedBytes.overflow else {
            throw Violation.arithmeticOverflow
        }

        // Meter limits are deliberately checked before Int32(frameCount) or AVAudioPCMBuffer
        // construction. maximumDecodedFrames is below Int32.max, so a corrupt large count fails
        // here instead of trapping during the framework conversion.
        try meter.record(
            decodedFrames: UInt64(frameCount),
            decodedPCMBytes: decodedBytes.partialValue
        )
        guard frameCount <= Int(Int32.max) else {
            throw Violation.decodedFrameLimit
        }
        return decodedBytes.partialValue
    }

    public struct Meter: Sendable {
        public private(set) var decodedFrames: UInt64 = 0
        public private(set) var decodedPCMBytes: UInt64 = 0
        public private(set) var sampleBuffers: UInt64 = 0

        public init() {}

        public mutating func record(decodedFrames frames: UInt64, decodedPCMBytes bytes: UInt64) throws {
            let bufferAddition = sampleBuffers.addingReportingOverflow(1)
            let frameAddition = decodedFrames.addingReportingOverflow(frames)
            let byteAddition = decodedPCMBytes.addingReportingOverflow(bytes)
            guard !bufferAddition.overflow, !frameAddition.overflow, !byteAddition.overflow else {
                throw Violation.arithmeticOverflow
            }
            guard bufferAddition.partialValue <= maximumSampleBuffers else {
                throw Violation.sampleBufferLimit
            }
            guard frameAddition.partialValue <= maximumDecodedFrames else {
                throw Violation.decodedFrameLimit
            }
            guard byteAddition.partialValue <= maximumDecodedPCMBytes else {
                throw Violation.decodedByteLimit
            }

            sampleBuffers = bufferAddition.partialValue
            decodedFrames = frameAddition.partialValue
            decodedPCMBytes = byteAddition.partialValue
        }
    }
}
