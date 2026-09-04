import Foundation
import XCTest

@testable import M3MCPCore

private actor DeadlineStartRecorder {
    private(set) var started = false

    func markStarted() {
        started = true
    }
}

final class SpeechPrivacyPolicyTests: XCTestCase {
    func testLegacyRecognitionRequiresOnDeviceCapability() {
        XCTAssertTrue(OnDeviceSpeechPolicy.permitsRecognition(supportsOnDeviceRecognition: true))
        XCTAssertFalse(OnDeviceSpeechPolicy.permitsRecognition(supportsOnDeviceRecognition: false))
        XCTAssertTrue(OnDeviceSpeechPolicy.unsupportedMessage.contains("did not submit"))
        XCTAssertTrue(OnDeviceSpeechPolicy.unsupportedMessage.contains("cloud speech processing is disabled"))
    }

    func testVoiceMemoTimeoutContractRejectsOutOfRangeAndReservesTransportOverhead() {
        XCTAssertNil(VoiceMemoTranscriptionTimeoutPolicy.validatedProviderSeconds(-1))
        XCTAssertEqual(VoiceMemoTranscriptionTimeoutPolicy.validatedProviderSeconds(450), 450)
        XCTAssertNil(VoiceMemoTranscriptionTimeoutPolicy.validatedProviderSeconds(Int.max))
        XCTAssertEqual(
            VoiceMemoTranscriptionTimeoutPolicy.transportResponseTimeoutSeconds,
            VoiceMemoTranscriptionTimeoutPolicy.maximumSeconds
                + VoiceMemoTranscriptionTimeoutPolicy.transportResponseOverheadSeconds
        )
        XCTAssertGreaterThan(
            VoiceMemoTranscriptionTimeoutPolicy.transportResponseTimeoutSeconds,
            VoiceMemoTranscriptionTimeoutPolicy.maximumSeconds
        )
    }

    func testWholeToolBudgetGivesFallbackOnlyAnalyzerRemainder() {
        let start: UInt64 = 1_000_000_000
        let budget = VoiceMemoTranscriptionBudget(
            seconds: 10,
            startNanoseconds: start
        )

        let analyzerStage = budget.remainingSeconds(
            nowNanoseconds: start + 1_000_000_000
        )
        let fallbackStage = budget.remainingSeconds(
            nowNanoseconds: start + 7_500_000_000
        )

        XCTAssertEqual(analyzerStage, 9, accuracy: 0.000_001)
        XCTAssertEqual(fallbackStage, 2.5, accuracy: 0.000_001)
        XCTAssertLessThan(fallbackStage, analyzerStage)
        XCTAssertEqual(
            budget.remainingSeconds(nowNanoseconds: start + 10_000_000_000),
            0
        )
    }

    func testAbsoluteBudgetRejectsLateCallbackEvenWhenScheduledTimerHasNotRun() {
        let start: UInt64 = 4_000_000_000
        let budget = VoiceMemoTranscriptionBudget(
            seconds: 2,
            startNanoseconds: start
        )

        // Models a final native callback racing a dispatch timer that was eligible at the
        // deadline but has not yet been scheduled by the runtime.
        XCTAssertTrue(
            budget.permitsCompletion(nowNanoseconds: start + 1_999_999_999)
        )
        XCTAssertFalse(
            budget.permitsCompletion(nowNanoseconds: start + 2_000_000_000)
        )
        XCTAssertFalse(
            budget.permitsCompletion(nowNanoseconds: start + 5_000_000_000)
        )
    }

    func testBudgetDeadlineIsNotRebasedWhenStageStartsLate() async {
        let now = DispatchTime.now().uptimeNanoseconds
        let budget = VoiceMemoTranscriptionBudget(
            seconds: 1,
            startNanoseconds: now >= 2_000_000_000
                ? now - 2_000_000_000
                : 0
        )
        let admission = AsyncOperationAdmission(maximumConcurrentOperations: 1)
        let recorder = DeadlineStartRecorder()

        do {
            _ = try await AsyncOperationDeadline.run(
                budget: budget,
                admission: admission
            ) {
                await recorder.markStarted()
                return "must not start"
            }
            XCTFail("Expected the already-expired absolute budget")
        } catch let timeout as AsyncOperationDeadline.TimedOut {
            XCTAssertEqual(timeout.seconds, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let operationStarted = await recorder.started
        XCTAssertFalse(operationStarted)
        XCTAssertEqual(admission.activeOperationCount, 0)
    }

    func testDeadlineReturnsCompletedOperation() async throws {
        let admission = AsyncOperationAdmission(maximumConcurrentOperations: 1)
        let value = try await AsyncOperationDeadline.run(seconds: 1, admission: admission) {
            "local-result"
        }

        XCTAssertEqual(value, "local-result")
        XCTAssertEqual(admission.activeOperationCount, 0)
    }

    func testDeadlineCancelsSlowOperation() async {
        let admission = AsyncOperationAdmission(maximumConcurrentOperations: 1)
        let started = DispatchTime.now().uptimeNanoseconds

        do {
            _ = try await AsyncOperationDeadline.run(seconds: 0.02, admission: admission) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "too late"
            }
            XCTFail("Expected deadline to expire")
        } catch let error as AsyncOperationDeadline.TimedOut {
            XCTAssertEqual(error.seconds, 0.02, accuracy: 0.001)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertLessThan(elapsed, 1)
        XCTAssertEqual(admission.activeOperationCount, 0)
    }

    func testDeadlineReturnsWhileCancellationIgnoringChildFinishesUnderAdmissionLease() async {
        let admission = AsyncOperationAdmission(maximumConcurrentOperations: 1)
        let started = DispatchTime.now().uptimeNanoseconds

        do {
            _ = try await AsyncOperationDeadline.run(seconds: 0.02, admission: admission) {
                // A framework callback bridged through a continuation does not automatically react
                // to Task cancellation. This deliberately completes later to exercise that shape.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                        continuation.resume()
                    }
                }
                return "late"
            }
            XCTFail("Expected deadline to expire")
        } catch is AsyncOperationDeadline.TimedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.15)
        XCTAssertEqual(admission.activeOperationCount, 1)

        do {
            _ = try await AsyncOperationDeadline.run(seconds: 1, admission: admission) {
                "must not start"
            }
            XCTFail("Expected the lingering operation to retain the admission lease")
        } catch let busy as AsyncOperationDeadline.ResourceBusy {
            XCTAssertEqual(busy.maximumConcurrentOperations, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(admission.activeOperationCount, 0)
        let recovered = try? await AsyncOperationDeadline.run(seconds: 1, admission: admission) {
            "recovered"
        }
        XCTAssertEqual(recovered, "recovered")
    }

    func testCallerCancellationReturnsWhileIgnoringChildRetainsLease() async {
        let admission = AsyncOperationAdmission(maximumConcurrentOperations: 1)
        let task = Task {
            try await AsyncOperationDeadline.run(seconds: 5, admission: admission) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                        continuation.resume()
                    }
                }
                return "late"
            }
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        let started = DispatchTime.now().uptimeNanoseconds
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.15)
        XCTAssertEqual(admission.activeOperationCount, 1)
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(admission.activeOperationCount, 0)
    }

    func testCancellationBeforeTaskInstallationNeverStartsOperation() async {
        let admission = AsyncOperationAdmission(maximumConcurrentOperations: 1)
        let reachedPreInstall = DispatchSemaphore(value: 0)
        let releasePreInstall = DispatchSemaphore(value: 0)
        let recorder = DeadlineStartRecorder()

        let task = Task {
            try await AsyncOperationDeadline.runForTesting(
                seconds: 5,
                admission: admission,
                beforeOperationTaskInstallation: {
                    reachedPreInstall.signal()
                    _ = releasePreInstall.wait(timeout: .now() + 2)
                }
            ) {
                await recorder.markStarted()
                return "must not run"
            }
        }

        XCTAssertEqual(reachedPreInstall.wait(timeout: .now() + 1), .success)
        task.cancel()
        releasePreInstall.signal()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await waitForAdmissionToDrain(admission)
        let started = await recorder.started
        XCTAssertFalse(started)
        XCTAssertEqual(admission.activeOperationCount, 0)
    }

    func testExpiredAbsoluteDeadlineBeforeInstallationNeverStartsOperation() async {
        let admission = AsyncOperationAdmission(maximumConcurrentOperations: 1)
        let recorder = DeadlineStartRecorder()

        do {
            _ = try await AsyncOperationDeadline.runForTesting(
                seconds: 0.01,
                admission: admission,
                beforeOperationTaskInstallation: {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            ) {
                await recorder.markStarted()
                return "must not run"
            }
            XCTFail("Expected timeout")
        } catch is AsyncOperationDeadline.TimedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await waitForAdmissionToDrain(admission)
        let started = await recorder.started
        XCTAssertFalse(started)
        XCTAssertEqual(admission.activeOperationCount, 0)
    }

    func testTranscodeSourcePreflightAcceptsTypicalVoiceMemoAndRejectsResourceExcess() throws {
        XCTAssertNoThrow(
            try SpeechTranscodePolicy.validateSource(
                durationSeconds: SpeechTranscodePolicy.maximumSourceDurationSeconds,
                sampleRate: 48_000
            )
        )

        for (duration, sampleRate, expected) in [
            (Double.nan, 48_000.0, SpeechTranscodePolicy.Violation.invalidSourceDuration),
            (
                SpeechTranscodePolicy.maximumSourceDurationSeconds + 1,
                48_000.0,
                SpeechTranscodePolicy.Violation.sourceDurationLimit
            ),
            (60.0, Double.infinity, SpeechTranscodePolicy.Violation.invalidSourceSampleRate),
            (3_000.0, 192_000.0, SpeechTranscodePolicy.Violation.sourceFrameLimit)
        ] {
            XCTAssertThrowsError(
                try SpeechTranscodePolicy.validateSource(
                    durationSeconds: duration,
                    sampleRate: sampleRate
                )
            ) { error in
                XCTAssertEqual(error as? SpeechTranscodePolicy.Violation, expected)
            }
        }
    }

    func testTranscodeMeterEnforcesDecodedFrameAndByteBudgetsBeforeWriting() throws {
        XCTAssertLessThan(
            SpeechTranscodePolicy.maximumDecodedFrames,
            UInt64(Int32.max)
        )

        var corruptCount = SpeechTranscodePolicy.Meter()
        XCTAssertThrowsError(
            try SpeechTranscodePolicy.preflightBufferAllocation(
                frameCount: Int(Int32.max) + 1,
                bytesPerFrame: 4,
                bufferCount: 1,
                meter: &corruptCount
            )
        ) { error in
            XCTAssertEqual(error as? SpeechTranscodePolicy.Violation, .decodedFrameLimit)
        }

        var exact = SpeechTranscodePolicy.Meter()
        try exact.record(
            decodedFrames: SpeechTranscodePolicy.maximumDecodedFrames,
            decodedPCMBytes: SpeechTranscodePolicy.maximumDecodedPCMBytes
        )
        XCTAssertEqual(exact.decodedFrames, SpeechTranscodePolicy.maximumDecodedFrames)
        XCTAssertEqual(exact.decodedPCMBytes, SpeechTranscodePolicy.maximumDecodedPCMBytes)

        XCTAssertThrowsError(
            try exact.record(decodedFrames: 1, decodedPCMBytes: 0)
        ) { error in
            XCTAssertEqual(error as? SpeechTranscodePolicy.Violation, .decodedFrameLimit)
        }

        var bytes = SpeechTranscodePolicy.Meter()
        XCTAssertThrowsError(
            try bytes.record(
                decodedFrames: 0,
                decodedPCMBytes: SpeechTranscodePolicy.maximumDecodedPCMBytes + 1
            )
        ) { error in
            XCTAssertEqual(error as? SpeechTranscodePolicy.Violation, .decodedByteLimit)
        }

        var work = SpeechTranscodePolicy.Meter()
        for _ in 0..<SpeechTranscodePolicy.maximumSampleBuffers {
            try work.record(decodedFrames: 0, decodedPCMBytes: 0)
        }
        XCTAssertThrowsError(
            try work.record(decodedFrames: 0, decodedPCMBytes: 0)
        ) { error in
            XCTAssertEqual(error as? SpeechTranscodePolicy.Violation, .sampleBufferLimit)
        }
    }

    private func waitForAdmissionToDrain(_ admission: AsyncOperationAdmission) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while admission.activeOperationCount != 0,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
