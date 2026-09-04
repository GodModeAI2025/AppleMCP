import Foundation
import M3MCPCore
import XCTest
@testable import M3MCPApp

final class LegacySpeechRecognizerCancellationTests: XCTestCase {
    func testWholeLegacyBudgetReturnsWhileIgnoringPreflightRetainsAdmission() async {
        let admission = AsyncOperationAdmission(maximumConcurrentOperations: 1)
        let budget = VoiceMemoTranscriptionBudget(seconds: 0.02)
        let started = DispatchTime.now().uptimeNanoseconds

        do {
            _ = try await LegacySpeechRecognizer.runBudgetedOperation(
                budget: budget,
                admission: admission
            ) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                        continuation.resume()
                    }
                }
                return "late preflight"
            }
            XCTFail("Expected the whole legacy budget to expire")
        } catch is AsyncOperationDeadline.TimedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started
        ) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.15)
        XCTAssertEqual(admission.activeOperationCount, 1)

        do {
            _ = try await LegacySpeechRecognizer.runBudgetedOperation(
                budget: VoiceMemoTranscriptionBudget(seconds: 1),
                admission: admission
            ) {
                "must not start"
            }
            XCTFail("Expected lingering preflight to retain admission")
        } catch is AsyncOperationDeadline.ResourceBusy {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(admission.activeOperationCount, 0)
    }

    func testTimedOutLegacySessionRetainsAdmissionUntilBothNativeComponentsDrain() async {
        let admission = AsyncOperationAdmission(maximumConcurrentOperations: 1)
        let feeder = TestAsyncSignal()
        let recognition = TestAsyncSignal()

        do {
            _ = try await LegacySpeechRecognizer.runBudgetedOperation(
                budget: VoiceMemoTranscriptionBudget(seconds: 0.02),
                admission: admission
            ) {
                await LegacySpeechRecognizer.waitForSessionDrain(
                    feederDone: { await feeder.wait() },
                    recognitionDone: { await recognition.wait() }
                )
                return "drained"
            }
            XCTFail("Expected the caller deadline to expire")
        } catch is AsyncOperationDeadline.TimedOut {
            // Expected: caller returned while both simulated native components remain alive.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(admission.activeOperationCount, 1)
        await assertAdmissionIsBusy(admission)

        feeder.signal()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(admission.activeOperationCount, 1)
        await assertAdmissionIsBusy(admission)

        recognition.signal()
        await waitForAdmissionToDrain(admission)
        XCTAssertEqual(admission.activeOperationCount, 0)
    }

    func testCancellationBeforeRelayInstallationIsDeliveredOnceAndPreventsStart() {
        let relay = RecognitionCancellationRelay()
        let action = TestRecognitionTask()

        relay.cancel()
        relay.cancel()
        let shouldStart = relay.install {
            action.cancel()
        }
        relay.cancel()

        XCTAssertFalse(shouldStart)
        XCTAssertEqual(action.cancelCount, 1)
    }

    func testConcurrentRelayInstallationAndCancellationDeliversExactlyOnce() {
        for _ in 0..<500 {
            let relay = RecognitionCancellationRelay()
            let action = TestRecognitionTask()
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = relay.install {
                    action.cancel()
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                relay.cancel()
                group.leave()
            }

            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(action.cancelCount, 1)
        }
    }

    func testCancelledLongDeadlineTimerReleasesActionCapturePromptly() async {
        let released = expectation(description: "long-deadline action capture released")
        let timer = CancellableDeadlineTimer()

        XCTAssertTrue(
            armDeadlineTimer(
                timer,
                after: 1_800,
                captureReleaseExpectation: released
            )
        )

        timer.cancel()

        await fulfillment(of: [released], timeout: 1)
        // Keep the timer owner itself alive through the assertion. The captured session graph must
        // be released by `cancel()`, not as a side effect of destroying the timer object.
        withExtendedLifetime(timer) {}
    }

    func testConcurrentLongDeadlineTimerCancellationReleasesCaptureOnce() async {
        let released = expectation(description: "concurrently cancelled action capture released")
        released.assertForOverFulfill = true
        let timer = CancellableDeadlineTimer()

        XCTAssertTrue(
            armDeadlineTimer(
                timer,
                after: 1_800,
                captureReleaseExpectation: released
            )
        )

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            timer.cancel()
        }

        await fulfillment(of: [released], timeout: 1)
        withExtendedLifetime(timer) {}
    }

    func testCancellationBeforeDeadlineTimerArmRejectsAndReleasesAction() async {
        let released = expectation(description: "rejected timer action capture released")
        let timer = CancellableDeadlineTimer()
        timer.cancel()

        XCTAssertFalse(
            armDeadlineTimer(
                timer,
                after: 1_800,
                captureReleaseExpectation: released
            )
        )

        await fulfillment(of: [released], timeout: 1)
        withExtendedLifetime(timer) {}
    }

    func testDeadlineTimerFiresOnceAndCannotBeRearmed() async {
        let fired = expectation(description: "deadline timer fired")
        fired.assertForOverFulfill = true
        let timer = CancellableDeadlineTimer()

        XCTAssertTrue(timer.arm(after: 0.01) { fired.fulfill() })
        XCTAssertFalse(timer.arm(after: 0.01) { fired.fulfill() })

        await fulfillment(of: [fired], timeout: 1)
        timer.cancel()
        withExtendedLifetime(timer) {}
    }

    func testRecognitionCancellationWaitsForActualCompletedState() async {
        let taskBox = RecognitionTaskBox<TestRecognitionTask>()
        let frameworkTask = TestRecognitionTask()
        taskBox.install(frameworkTask)
        taskBox.cancel()

        let drainFinished = TestBooleanBox()
        let drainExpectation = expectation(description: "recognition task reached completed")
        Task {
            await taskBox.waitUntilCompleted(pollIntervalNanoseconds: 1_000_000)
            drainFinished.set(true)
            drainExpectation.fulfill()
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(drainFinished.value)
        XCTAssertEqual(frameworkTask.cancelCount, 1)

        frameworkTask.complete()
        await fulfillment(of: [drainExpectation], timeout: 1)
        XCTAssertTrue(drainFinished.value)
    }

    func testCancellationBeforeTaskInstallationCancelsLateTask() {
        let box = RecognitionTaskBox<TestRecognitionTask>()
        let task = TestRecognitionTask()

        box.cancel()
        box.install(task)

        XCTAssertEqual(task.cancelCount, 1)
    }

    func testCancellationBeforeTaskInstallationStillWaitsForLateTaskCompletion() async {
        let box = RecognitionTaskBox<TestRecognitionTask>()
        let task = TestRecognitionTask()

        box.cancel()
        let drain = Task {
            await box.waitUntilCompleted(pollIntervalNanoseconds: 1_000_000)
        }
        box.install(task)

        XCTAssertEqual(task.cancelCount, 1)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(task.hasCompletedRecognition)

        task.complete()
        await drain.value
    }

    func testCancellationAfterTaskInstallationCancelsLiveTaskOnce() {
        let box = RecognitionTaskBox<TestRecognitionTask>()
        let task = TestRecognitionTask()

        box.install(task)
        box.cancel()
        box.cancel()

        XCTAssertEqual(task.cancelCount, 1)
    }

    func testNoTaskBranchRejectsLateTaskAndCompletesDrain() async {
        let box = RecognitionTaskBox<TestRecognitionTask>()
        let task = TestRecognitionTask()

        box.markNoTaskWillBeInstalled()
        box.install(task)
        await box.waitUntilCompleted(pollIntervalNanoseconds: 1_000_000)

        XCTAssertEqual(task.cancelCount, 1)
    }

    func testConcurrentInstallationAndCancellationAlwaysCancelExactlyOnce() {
        for _ in 0..<500 {
            let box = RecognitionTaskBox<TestRecognitionTask>()
            let task = TestRecognitionTask()
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.install(task)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.cancel()
                group.leave()
            }

            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(task.cancelCount, 1)
        }
    }

    func testAudioEndIsSerializedAfterInFlightAppend() async {
        let appendEntered = expectation(description: "append entered")
        let probe = BlockingAudioMutationProbe(appendEntered: appendEntered)
        let source = OneElementSource(value: 42)

        let feeder = Task.detached {
            try await SerializedLegacyAudioFeed.run(
                next: { source.next() },
                permitsCompletion: { true },
                deadlineError: { CancellationError() },
                append: { probe.append($0) },
                endAudio: { probe.endAudio() }
            )
        }

        await fulfillment(of: [appendEntered], timeout: 1)
        feeder.cancel()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(probe.endCount, 0)
        XCTAssertFalse(probe.observedOverlap)

        probe.releaseAppend()
        _ = try? await feeder.value

        XCTAssertEqual(probe.endCount, 1)
        XCTAssertFalse(probe.observedOverlap)
    }

    private func assertAdmissionIsBusy(_ admission: AsyncOperationAdmission) async {
        do {
            _ = try await LegacySpeechRecognizer.runBudgetedOperation(
                budget: VoiceMemoTranscriptionBudget(seconds: 1),
                admission: admission
            ) {
                "must not start"
            }
            XCTFail("Expected the draining legacy operation to retain admission")
        } catch is AsyncOperationDeadline.ResourceBusy {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func waitForAdmissionToDrain(_ admission: AsyncOperationAdmission) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while admission.activeOperationCount != 0,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func armDeadlineTimer(
        _ timer: CancellableDeadlineTimer,
        after seconds: TimeInterval,
        captureReleaseExpectation: XCTestExpectation
    ) -> Bool {
        let capture = DeadlineActionCapture(
            releaseExpectation: captureReleaseExpectation
        )
        return timer.arm(after: seconds) { [capture] in
            capture.markInvoked()
        }
    }
}

private final class DeadlineActionCapture: @unchecked Sendable {
    private let releaseExpectation: XCTestExpectation

    init(releaseExpectation: XCTestExpectation) {
        self.releaseExpectation = releaseExpectation
    }

    func markInvoked() {}

    deinit {
        releaseExpectation.fulfill()
    }
}

private final class TestBooleanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Bool) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class TestRecognitionTask: RecognitionTaskCancelling, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationCount = 0
    private var completed = false

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationCount
    }

    var hasCompletedRecognition: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func cancel() {
        lock.lock()
        cancellationCount += 1
        lock.unlock()
    }

    func complete() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

private final class TestAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately: Bool
            lock.lock()
            if signalled {
                resumeImmediately = true
            } else {
                waiters.append(continuation)
                resumeImmediately = false
            }
            lock.unlock()

            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func signal() {
        let claimed: [CheckedContinuation<Void, Never>]
        lock.lock()
        signalled = true
        claimed = waiters
        waiters.removeAll()
        lock.unlock()

        for waiter in claimed {
            waiter.resume()
        }
    }
}

private final class OneElementSource<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Element?

    init(value: Element) {
        self.value = value
    }

    func next() -> Element? {
        lock.lock()
        defer { lock.unlock() }
        defer { value = nil }
        return value
    }
}

private final class BlockingAudioMutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let appendEntered: XCTestExpectation
    private let appendRelease = DispatchSemaphore(value: 0)
    private var appendActive = false
    private var overlap = false
    private var ends = 0

    init(appendEntered: XCTestExpectation) {
        self.appendEntered = appendEntered
    }

    var observedOverlap: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overlap
    }

    var endCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ends
    }

    func append(_ value: Int) {
        _ = value
        lock.lock()
        if appendActive {
            overlap = true
        }
        appendActive = true
        lock.unlock()

        appendEntered.fulfill()
        appendRelease.wait()

        lock.lock()
        appendActive = false
        lock.unlock()
    }

    func endAudio() {
        lock.lock()
        overlap = overlap || appendActive
        ends += 1
        lock.unlock()
    }

    func releaseAppend() {
        appendRelease.signal()
    }
}
