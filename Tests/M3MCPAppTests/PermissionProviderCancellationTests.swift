import Foundation
import XCTest
@testable import M3MCPApp

final class PermissionProviderCancellationTests: XCTestCase {
    func testPrecancelledMainActorBoundariesDoNotActivateAppOrOpenSettings() async {
        let effects = PermissionUISideEffectLog()
        let provider = PermissionProvider(
            settingsOpener: { url in
                effects.record("open:\(url.absoluteString)")
                return true
            },
            appActivator: {
                effects.record("activate")
            }
        )

        let operation = Task {
            // Give the caller a deterministic cancellation point before either MainActor side
            // effect boundary, modelling cancellation while the actor is busy.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let activated = await provider.activateForPermissionPrompt()
            let response = await provider.openSettings(input: ["pane": .string("calendar")])
            return (activated, response)
        }
        operation.cancel()

        let result = await operation.value
        XCTAssertFalse(result.0)
        XCTAssertFalse(result.1.ok)
        XCTAssertTrue(result.1.message?.contains("cancelled") == true)
        XCTAssertEqual(effects.values, [])
    }

    func testCancellingActiveCallbackStageReturnsPromptlyAndSuppressesLateCallback() async {
        let callbackInstalled = expectation(description: "TCC callback installed")
        let callback = PermissionCallbackBox<Int>()

        let operation = Task<Int, Error> {
            try await awaitCancellableCallback { completion in
                callback.set(completion)
                callbackInstalled.fulfill()
                // Model a framework that leaves its system prompt open and never calls back after
                // the requesting task disconnects.
            }
        }

        await fulfillment(of: [callbackInstalled], timeout: 1)
        operation.cancel()

        let completed = expectation(description: "cancelled callback bridge returned promptly")
        let outcome = PermissionCancellationOutcome()
        Task {
            do {
                _ = try await operation.value
                outcome.set(false)
            } catch {
                outcome.set(error is CancellationError)
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(outcome.value, true)

        // A framework callback may arrive after the user eventually closes the native prompt. It
        // must be ignored rather than resuming the continuation a second time.
        callback.complete(.success(42))
    }

    func testCancellableActiveStageLetsSequenceSkipLaterPromptsWithoutNativeCallback() async {
        let callbackInstalled = expectation(description: "active permission callback installed")
        let callback = PermissionCallbackBox<String>()
        let executions = PermissionStageExecutionLog()

        let operation = Task {
            await PermissionRequestSequence.run([
                {
                    executions.append("first")
                    return "first-result"
                },
                {
                    executions.append("active")
                    do {
                        return try await awaitCancellableCallback { completion in
                            callback.set(completion)
                            callbackInstalled.fulfill()
                        }
                    } catch {
                        return "cancelled-result"
                    }
                },
                {
                    executions.append("third")
                    return "third-result"
                }
            ])
        }

        await fulfillment(of: [callbackInstalled], timeout: 1)
        operation.cancel()
        let result = await operation.value

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.items, ["first-result", "cancelled-result"])
        XCTAssertEqual(executions.values, ["first", "active"])
        callback.complete(.success("late-result"))
    }

    func testCancellationWhileStageIsBlockedReturnsPartialResultsAndSkipsAllLaterStages() async {
        let blockedStageStarted = expectation(description: "blocked permission stage started")
        let blockedStage = SuspendedPermissionStage()
        let executions = PermissionStageExecutionLog()

        let operation = Task {
            await PermissionRequestSequence.run([
                {
                    executions.append("first")
                    return "first-result"
                },
                {
                    executions.append("blocked")
                    blockedStageStarted.fulfill()
                    await blockedStage.wait()
                    return "blocked-result"
                },
                {
                    executions.append("third")
                    return "third-result"
                },
                {
                    executions.append("fourth")
                    return "fourth-result"
                }
            ])
        }

        await fulfillment(of: [blockedStageStarted], timeout: 1)
        operation.cancel()

        // The sequence also remains safe for a future stage that has no cancellable callback bridge:
        // it must not allow any following request to begin when that stage eventually returns.
        XCTAssertEqual(executions.values, ["first", "blocked"])
        blockedStage.release()

        let result = await operation.value
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.items, ["first-result", "blocked-result"])
        XCTAssertEqual(executions.values, ["first", "blocked"])
    }
}

private final class PermissionUISideEffectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class PermissionCallbackBox<Value>: @unchecked Sendable {
    typealias Callback = (Result<Value, Error>) -> Void

    private let lock = NSLock()
    private var callback: Callback?

    func set(_ callback: @escaping Callback) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func complete(_ result: Result<Value, Error>) {
        let callback: Callback?
        lock.lock()
        callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(result)
    }
}

private final class PermissionCancellationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?

    var value: Bool? {
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

private final class SuspendedPermissionStage: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReleased {
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
        isReleased = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class PermissionStageExecutionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
