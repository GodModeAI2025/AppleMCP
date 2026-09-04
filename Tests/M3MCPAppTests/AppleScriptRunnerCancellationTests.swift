import Foundation
import XCTest
@testable import M3MCPApp

final class AppleScriptRunnerCancellationTests: XCTestCase {
    func testTaskCancellationReturnsPromptlyButGateStaysHeldUntilWorkerReturns() async {
        let gate = AppleEventExecutionGate()
        let workerStarted = expectation(description: "blocking executor started")
        let releaseWorker = DispatchSemaphore(value: 0)
        let executions = AppleScriptExecutionCounter()

        let first = Task {
            await AppleScriptRunner.runForTesting(
                "first",
                timeout: 60,
                gate: gate
            ) { _ in
                executions.increment()
                workerStarted.fulfill()
                releaseWorker.wait()
                return .success("released")
            }
        }

        await fulfillment(of: [workerStarted], timeout: 1)
        first.cancel()
        let firstResult = await promptlyObserve(first)
        XCTAssertEqual(failureMessage(firstResult), "AppleScript request was cancelled.")

        let second = await AppleScriptRunner.runForTesting(
            "second",
            timeout: 1,
            gate: gate
        ) { _ in
            XCTFail("a second executor must not start while the native call is blocked")
            return .success("unexpected")
        }
        XCTAssertTrue(failureMessage(second)?.contains("already executing") == true)
        XCTAssertEqual(executions.value, 1)

        releaseWorker.signal()
        let recovered = await waitForSuccessfulExecution(gate: gate)
        XCTAssertEqual(recovered, "recovered")
        XCTAssertEqual(executions.value, 1)
    }

    func testTimeoutReturnsPromptlyAndAlsoRetainsSingleFlightAdmission() async {
        let gate = AppleEventExecutionGate()
        let workerStarted = expectation(description: "blocking executor started")
        let releaseWorker = DispatchSemaphore(value: 0)

        let first = Task {
            await AppleScriptRunner.runForTesting(
                "first",
                timeout: 0.05,
                gate: gate
            ) { _ in
                workerStarted.fulfill()
                releaseWorker.wait()
                return .success("released")
            }
        }

        await fulfillment(of: [workerStarted], timeout: 1)
        let firstResult = await promptlyObserve(first)
        XCTAssertTrue(failureMessage(firstResult)?.contains("timed out") == true)

        let second = await AppleScriptRunner.runForTesting(
            "second",
            timeout: 1,
            gate: gate
        ) { _ in
            XCTFail("timeout must not release the gate while the native worker is still blocked")
            return .success("unexpected")
        }
        XCTAssertTrue(failureMessage(second)?.contains("already executing") == true)

        releaseWorker.signal()
        let recovered = await waitForSuccessfulExecution(gate: gate)
        XCTAssertEqual(recovered, "recovered")
    }

    func testCancellationBeforeDispatchDoesNotRunExecutor() async {
        let gate = AppleEventExecutionGate()
        let executions = AppleScriptExecutionCounter()

        let operation = Task {
            await AppleScriptRunner.runForTesting(
                "cancelled",
                timeout: 1,
                gate: gate
            ) { _ in
                executions.increment()
                return .success("unexpected")
            }
        }
        operation.cancel()

        let result = await promptlyObserve(operation)
        XCTAssertEqual(failureMessage(result), "AppleScript request was cancelled.")
        XCTAssertEqual(executions.value, 0)

        let next = await AppleScriptRunner.runForTesting(
            "next",
            timeout: 1,
            gate: gate
        ) { _ in .success("available") }
        XCTAssertEqual(successValue(next), "available")
    }

    private func promptlyObserve(
        _ operation: Task<Result<String, AppleScriptRunner.Failure>, Never>
    ) async -> Result<String, AppleScriptRunner.Failure> {
        let completed = expectation(description: "runner returned promptly")
        let box = AppleScriptResultBox()
        Task {
            box.set(await operation.value)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        return box.value ?? .failure(.init(message: "test did not capture a result"))
    }

    private func waitForSuccessfulExecution(gate: AppleEventExecutionGate) async -> String? {
        for _ in 0..<100 {
            let result = await AppleScriptRunner.runForTesting(
                "recovery",
                timeout: 1,
                gate: gate
            ) { _ in .success("recovered") }
            if case .success(let value) = result {
                return value
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func failureMessage(
        _ result: Result<String, AppleScriptRunner.Failure>
    ) -> String? {
        guard case .failure(let failure) = result else { return nil }
        return failure.message
    }

    private func successValue(
        _ result: Result<String, AppleScriptRunner.Failure>
    ) -> String? {
        guard case .success(let value) = result else { return nil }
        return value
    }
}

private final class AppleScriptExecutionCounter: @unchecked Sendable {
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

private final class AppleScriptResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<String, AppleScriptRunner.Failure>?

    var value: Result<String, AppleScriptRunner.Failure>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ result: Result<String, AppleScriptRunner.Failure>) {
        lock.lock()
        storage = result
        lock.unlock()
    }
}
