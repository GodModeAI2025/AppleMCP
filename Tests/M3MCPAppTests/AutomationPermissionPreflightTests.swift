import CoreServices
import Foundation
import XCTest
@testable import M3MCPApp

final class AutomationPermissionPreflightTests: XCTestCase {
    func testNativeDeterminationRunsOffMainThread() async {
        let gate = AppleEventExecutionGate()
        let observation = AutomationThreadObservation()

        let result = await AutomationPermission.runDeterminationForTesting(
            prompt: false,
            timeout: 1,
            gate: gate
        ) { prompt in
            observation.record(isMainThread: Thread.isMainThread, prompt: prompt)
            return AutomationPermission.Status(state: "authorized", message: nil, osStatus: noErr)
        }

        XCTAssertTrue(result.isAuthorized)
        XCTAssertEqual(observation.isMainThread, false)
        XCTAssertEqual(observation.prompt, false)
    }

    func testCancellationReturnsPromptlyWhileGateRemainsHeldUntilNativeCallEnds() async {
        let gate = AppleEventExecutionGate()
        let nativeCallStarted = expectation(description: "native determination started")
        let releaseNativeCall = DispatchSemaphore(value: 0)
        let executions = AutomationExecutionCounter()

        let first = Task {
            await AutomationPermission.runDeterminationForTesting(
                prompt: true,
                timeout: 60,
                gate: gate
            ) { _ in
                executions.increment()
                nativeCallStarted.fulfill()
                releaseNativeCall.wait()
                return AutomationPermission.Status(state: "authorized", message: nil, osStatus: noErr)
            }
        }

        await fulfillment(of: [nativeCallStarted], timeout: 1)
        first.cancel()
        let firstResult = await promptlyObserve(first)
        XCTAssertEqual(firstResult.state, "cancelled")

        let blocked = await AutomationPermission.runDeterminationForTesting(
            prompt: false,
            timeout: 1,
            gate: gate
        ) { _ in
            XCTFail("a second native determination must not start while the first is blocked")
            return AutomationPermission.Status(state: "authorized", message: nil)
        }
        XCTAssertEqual(blocked.state, "busy")
        XCTAssertEqual(executions.value, 1)

        let blockedScript = await AppleScriptRunner.runForTesting(
            "shared gate",
            timeout: 1,
            gate: gate
        ) { _ in
            XCTFail("AppleScript must share admission with Automation determination")
            return .success("unexpected")
        }
        guard case .failure(let blockedScriptFailure) = blockedScript else {
            XCTFail("AppleScript should fail fast while Automation determination owns the gate")
            releaseNativeCall.signal()
            return
        }
        XCTAssertTrue(blockedScriptFailure.message.contains("already executing"))

        releaseNativeCall.signal()
        let recovered = await waitForSuccessfulDetermination(gate: gate)
        XCTAssertTrue(recovered?.isAuthorized == true)

        // The worker's late authorized result must not replace or resume the cancelled caller.
        let stableFirstResult = await first.value
        XCTAssertEqual(stableFirstResult, firstResult)
        XCTAssertEqual(executions.value, 1)
    }

    func testTimeoutReturnsPromptlyAndRetainsGateUntilLateNativeCompletion() async {
        let gate = AppleEventExecutionGate()
        let nativeCallStarted = expectation(description: "timed native determination started")
        let releaseNativeCall = DispatchSemaphore(value: 0)

        let first = Task {
            await AutomationPermission.runDeterminationForTesting(
                prompt: false,
                timeout: 0.05,
                gate: gate
            ) { _ in
                nativeCallStarted.fulfill()
                releaseNativeCall.wait()
                return AutomationPermission.Status(state: "authorized", message: nil, osStatus: noErr)
            }
        }

        await fulfillment(of: [nativeCallStarted], timeout: 1)
        let firstResult = await promptlyObserve(first)
        XCTAssertEqual(firstResult.state, "timed_out")

        let blocked = await AutomationPermission.runDeterminationForTesting(
            prompt: false,
            timeout: 1,
            gate: gate
        ) { _ in
            XCTFail("timeout must not release admission while the native call is still blocked")
            return AutomationPermission.Status(state: "authorized", message: nil)
        }
        XCTAssertEqual(blocked.state, "busy")

        releaseNativeCall.signal()
        let recovered = await waitForSuccessfulDetermination(gate: gate)
        XCTAssertTrue(recovered?.isAuthorized == true)
        let stableFirstResult = await first.value
        XCTAssertEqual(stableFirstResult, firstResult)
    }

    func testStatusPreflightNeverLaunchesAndNeverEnablesPrompting() async {
        let log = AutomationPreflightLog()
        let notRunning = AutomationPermission.Status(
            state: "error",
            message: "Application is not running.",
            osStatus: OSStatus(procNotFound)
        )

        let result = await AutomationPermission.resolvePreflightForTesting(
            purpose: .status,
            determine: { prompt in
                log.recordDetermination(prompt: prompt)
                return notRunning
            },
            launchHidden: {
                log.recordLaunch()
                return .launched
            }
        )

        XCTAssertEqual(result, notRunning)
        XCTAssertEqual(log.prompts, [false])
        XCTAssertEqual(log.launchCount, 0)
    }

    func testToolPreflightLaunchesHiddenThenRetriesWithPromptDisabled() async {
        let log = AutomationPreflightLog()

        let result = await AutomationPermission.resolvePreflightForTesting(
            purpose: .toolExecution,
            determine: { prompt in
                let attempt = log.recordDetermination(prompt: prompt)
                if attempt == 1 {
                    return AutomationPermission.Status(
                        state: "error",
                        message: "Application is not running.",
                        osStatus: OSStatus(procNotFound)
                    )
                }
                return AutomationPermission.Status(state: "authorized", message: nil, osStatus: noErr)
            },
            launchHidden: {
                log.recordLaunch()
                return .launched
            }
        )

        XCTAssertTrue(result.isAuthorized)
        XCTAssertEqual(log.prompts, [false, false])
        XCTAssertEqual(log.launchCount, 1)
    }

    func testDeniedToolPreflightDoesNotLaunchTarget() async {
        let log = AutomationPreflightLog()
        let denied = AutomationPermission.Status(
            state: "denied",
            message: "Automation approval was denied.",
            osStatus: OSStatus(errAEEventNotPermitted)
        )

        let result = await AutomationPermission.resolvePreflightForTesting(
            purpose: .toolExecution,
            determine: { prompt in
                log.recordDetermination(prompt: prompt)
                return denied
            },
            launchHidden: {
                log.recordLaunch()
                return .launched
            }
        )

        XCTAssertEqual(result, denied)
        XCTAssertEqual(log.prompts, [false])
        XCTAssertEqual(log.launchCount, 0)
    }

    func testCancellationAtHiddenLaunchBoundaryPreventsInjectedLaunchActionAndRetry() async {
        let log = AutomationPreflightLog()
        let launcherEntered = expectation(description: "hidden launcher entered")
        let releaseLauncher = AutomationTestSuspension()

        let operation = Task {
            await AutomationPermission.resolvePreflightForTesting(
                purpose: .toolExecution,
                determine: { prompt in
                    log.recordDetermination(prompt: prompt)
                    return AutomationPermission.Status(
                        state: "error",
                        message: "Application is not running.",
                        osStatus: OSStatus(procNotFound)
                    )
                },
                launchHidden: {
                    launcherEntered.fulfill()
                    await releaseLauncher.wait()
                    guard !Task.isCancelled else { return .cancelled }
                    log.recordLaunch()
                    return .launched
                }
            )
        }

        await fulfillment(of: [launcherEntered], timeout: 1)
        operation.cancel()
        releaseLauncher.release()
        let result = await operation.value

        XCTAssertEqual(result.state, "cancelled")
        XCTAssertEqual(log.prompts, [false])
        XCTAssertEqual(log.launchCount, 0)
    }

    private func promptlyObserve(
        _ operation: Task<AutomationPermission.Status, Never>
    ) async -> AutomationPermission.Status {
        let completed = expectation(description: "automation determination returned promptly")
        let box = AutomationStatusBox()
        Task {
            box.set(await operation.value)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        return box.value ?? .init(state: "test_error", message: "test did not capture a result")
    }

    private func waitForSuccessfulDetermination(
        gate: AppleEventExecutionGate
    ) async -> AutomationPermission.Status? {
        for _ in 0..<100 {
            let result = await AutomationPermission.runDeterminationForTesting(
                prompt: false,
                timeout: 1,
                gate: gate
            ) { _ in
                AutomationPermission.Status(state: "authorized", message: nil, osStatus: noErr)
            }
            if result.isAuthorized { return result }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}

private final class AutomationThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadStorage: Bool?
    private var promptStorage: Bool?

    var isMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadStorage
    }

    var prompt: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return promptStorage
    }

    func record(isMainThread: Bool, prompt: Bool) {
        lock.lock()
        mainThreadStorage = isMainThread
        promptStorage = prompt
        lock.unlock()
    }
}

private final class AutomationExecutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class AutomationStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AutomationPermission.Status?

    var value: AutomationPermission.Status? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: AutomationPermission.Status) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class AutomationPreflightLog: @unchecked Sendable {
    private let lock = NSLock()
    private var promptStorage: [Bool] = []
    private var launchStorage = 0

    var prompts: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return promptStorage
    }

    var launchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return launchStorage
    }

    @discardableResult
    func recordDetermination(prompt: Bool) -> Int {
        lock.lock()
        promptStorage.append(prompt)
        let count = promptStorage.count
        lock.unlock()
        return count
    }

    func recordLaunch() {
        lock.lock()
        launchStorage += 1
        lock.unlock()
    }
}

private final class AutomationTestSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        released = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
