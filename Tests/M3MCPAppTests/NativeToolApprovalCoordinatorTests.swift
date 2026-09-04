import Foundation
import XCTest
@testable import M3MCPApp
@testable import M3MCPCore

final class NativeToolApprovalCoordinatorTests: XCTestCase {
    func testCancellationBeforeContinuationInstallationNeverEnqueuesOrPresents() async {
        let hookEntered = expectation(description: "pre-install hook entered")
        let hookGate = ApprovalTestGate()
        let enqueueCount = ApprovalLockedCounter()

        let coordinator = await MainActor.run {
            NativeToolApprovalCoordinator(
                timeout: 30,
                beforeContinuationInstallation: {
                    hookEntered.fulfill()
                    await hookGate.wait()
                },
                enqueueObserver: {
                    enqueueCount.increment()
                }
            )
        }
        let request = M3MCPToolApprovalRequest(
            tool: .calendarDeleteEvent,
            input: ["id": .string("event-1")]
        )

        let operation = Task {
            await coordinator.requestApproval(for: request)
        }
        await fulfillment(of: [hookEntered], timeout: 1)

        operation.cancel()
        await hookGate.open()
        let approved = await operation.value

        XCTAssertFalse(approved)
        XCTAssertEqual(enqueueCount.value, 0)
    }
}

private actor ApprovalTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        opened = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ApprovalLockedCounter: @unchecked Sendable {
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
