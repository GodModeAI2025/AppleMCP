import Foundation
import XCTest
@testable import M3MCPCore

final class InFlightRequestRegistryTests: XCTestCase {
    func testResponseCheckRetainsAdmissionUntilExplicitFinish() throws {
        let registry = M3MCPInFlightRequestRegistry(maximumEntries: 1)
        let reservation = try XCTUnwrap(registry.reserve(.integer(1)))

        XCTAssertTrue(registry.responseIsWanted(reservation))
        XCTAssertEqual(registry.count, 1)
        XCTAssertNil(registry.reserve(.integer(2)))
        XCTAssertTrue(registry.finish(reservation))
        XCTAssertEqual(registry.count, 0)
        XCTAssertNotNil(registry.reserve(.integer(2)))
    }

    func testDuplicateReservationCannotReplaceOriginalAndIDCanBeReusedAfterFinish() throws {
        let registry = M3MCPInFlightRequestRegistry()
        let original = try XCTUnwrap(registry.reserve(.string("same")))

        XCTAssertNil(registry.reserve(.string("same")))
        XCTAssertEqual(registry.count, 1)
        XCTAssertTrue(registry.finish(original))
        XCTAssertEqual(registry.count, 0)

        let reused = try XCTUnwrap(registry.reserve(.string("same")))
        XCTAssertNotEqual(original, reused)
        XCTAssertFalse(registry.finish(original), "A stale completion must not remove a newer call")
        XCTAssertTrue(registry.isInFlight(.string("same")))
        XCTAssertTrue(registry.finish(reused))
    }

    func testCancellationBeforeHandlerAttachmentInvokesHandlerAndSuppressesResponse() throws {
        let registry = M3MCPInFlightRequestRegistry()
        let counter = LockedCounter()
        let reservation = try XCTUnwrap(registry.reserve(.integer(1)))

        XCTAssertTrue(registry.cancel(.integer(1)))
        XCTAssertTrue(registry.attachCancellationHandler(to: reservation) {
            counter.increment()
        })
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(registry.cancel(.integer(1)))
        XCTAssertEqual(counter.value, 1, "Repeated cancellation must not repeat transport shutdown")
        XCTAssertFalse(registry.finish(reservation))
        XCTAssertEqual(registry.count, 0)
    }

    func testAttachedHandlerRunsAtMostOnceUnderConcurrentCancellation() throws {
        let registry = M3MCPInFlightRequestRegistry()
        let counter = LockedCounter()
        let reservation = try XCTUnwrap(registry.reserve(.integer(2)))
        XCTAssertTrue(registry.attachCancellationHandler(to: reservation) {
            counter.increment()
        })

        let group = DispatchGroup()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                _ = registry.cancel(.integer(2))
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(registry.finish(reservation))
    }

    func testUnknownCancellationIsANoop() {
        let registry = M3MCPInFlightRequestRegistry()
        XCTAssertFalse(registry.cancel(.string("missing")))
        XCTAssertEqual(registry.count, 0)
    }

    func testCapacityBoundRejectsAdditionalWorkUntilASlotFinishes() throws {
        let registry = M3MCPInFlightRequestRegistry(maximumEntries: 2)
        let first = try XCTUnwrap(registry.reserve(.integer(1)))
        let second = try XCTUnwrap(registry.reserve(.integer(2)))
        XCTAssertNil(registry.reserve(.integer(3)))
        XCTAssertEqual(registry.count, 2)

        XCTAssertTrue(registry.finish(first))
        let third = try XCTUnwrap(registry.reserve(.integer(3)))
        XCTAssertTrue(registry.finish(second))
        XCTAssertTrue(registry.finish(third))
    }

    func testCancelAllInterruptsEveryAttachedCallAndSuppressesTheirResponses() throws {
        let registry = M3MCPInFlightRequestRegistry()
        let counter = LockedCounter()
        let first = try XCTUnwrap(registry.reserve(.integer(1)))
        let second = try XCTUnwrap(registry.reserve(.integer(2)))
        XCTAssertTrue(registry.attachCancellationHandler(to: first) { counter.increment() })
        XCTAssertTrue(registry.attachCancellationHandler(to: second) { counter.increment() })

        registry.cancelAll()
        registry.cancelAll()

        XCTAssertEqual(counter.value, 2)
        XCTAssertFalse(registry.finish(first))
        XCTAssertFalse(registry.finish(second))
        XCTAssertEqual(registry.count, 0)
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
