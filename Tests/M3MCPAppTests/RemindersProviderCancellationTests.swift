import Foundation
import XCTest
@testable import M3MCPApp

final class RemindersProviderCancellationTests: XCTestCase {
    func testCancellationBeforeContinuationInstallPreventsRequestStart() async {
        let relay = ReminderFetchCancellationRelay<Int>()
        relay.cancel()

        let operation = Task<Int, Error> {
            try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(relay.installContinuation(continuation))
            }
        }

        await assertCancelled(operation)
    }

    func testCancellationWithoutEventKitCallbackResumesContinuationAndCancelsToken() async {
        let relay = ReminderFetchCancellationRelay<Int>()
        let continuationInstalled = expectation(description: "continuation installed")
        let cancellationCount = LockedCounter()

        let operation = Task<Int, Error> {
            try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(relay.installContinuation(continuation))
                relay.installRequestCancellation {
                    cancellationCount.increment()
                }
                continuationInstalled.fulfill()
                // EventKit intentionally does not invoke its callback after cancellation.
            }
        }

        await fulfillment(of: [continuationInstalled], timeout: 1)
        relay.cancel()

        await assertCancelled(operation)
        XCTAssertEqual(cancellationCount.value, 1)
        relay.cancel()
        XCTAssertEqual(cancellationCount.value, 1)
    }

    func testCancellationBeforeOpaqueTokenInstallCancelsLateToken() async {
        let relay = ReminderFetchCancellationRelay<Int>()
        let continuationInstalled = expectation(description: "continuation installed")
        let cancellationCount = LockedCounter()

        let operation = Task<Int, Error> {
            try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(relay.installContinuation(continuation))
                continuationInstalled.fulfill()
            }
        }

        await fulfillment(of: [continuationInstalled], timeout: 1)
        relay.cancel()
        relay.installRequestCancellation {
            cancellationCount.increment()
        }

        await assertCancelled(operation)
        XCTAssertEqual(cancellationCount.value, 1)
    }

    func testSynchronousCallbackBeforeTokenInstallDoesNotCancelCompletedRequest() async throws {
        let relay = ReminderFetchCancellationRelay<Int>()
        let cancellationCount = LockedCounter()

        let result = try await withCheckedThrowingContinuation { continuation in
            XCTAssertTrue(relay.installContinuation(continuation))
            relay.complete(.success(42))
            relay.installRequestCancellation {
                cancellationCount.increment()
            }
        }

        XCTAssertEqual(result, 42)
        XCTAssertEqual(cancellationCount.value, 0)
    }

    func testCompletionAndCancellationRaceResumesExactlyOnce() async {
        for value in 0..<250 {
            let relay = ReminderFetchCancellationRelay<Int>()
            let installed = expectation(description: "iteration \(value) installed")
            let operation = Task<Int, Error> {
                try await withCheckedThrowingContinuation { continuation in
                    XCTAssertTrue(relay.installContinuation(continuation))
                    relay.installRequestCancellation {}
                    installed.fulfill()
                }
            }
            await fulfillment(of: [installed], timeout: 1)

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                relay.complete(.success(value))
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                relay.cancel()
                group.leave()
            }
            XCTAssertEqual(group.wait(timeout: .now() + 1), .success)

            do {
                let returned = try await operation.value
                XCTAssertEqual(returned, value)
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    private func assertCancelled(
        _ operation: Task<Int, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let completed = expectation(description: "operation completed promptly")
        let outcome = LockedCancellationOutcome()

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
        XCTAssertEqual(outcome.value, true, file: file, line: line)
    }
}

private final class LockedCounter: @unchecked Sendable {
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

private final class LockedCancellationOutcome: @unchecked Sendable {
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
