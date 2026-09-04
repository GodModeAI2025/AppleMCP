import Foundation
import M3MCPCore
import XCTest
@testable import M3MCPApp

final class NotesProviderExecutionBoundaryTests: XCTestCase {
    func testMissingReadIDIsRejectedBeforePermissionPreflightOrScript() async {
        let log = NotesExecutionLog()
        let provider = makeProvider(log: log)

        let response = await provider.read(input: [:])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("Missing required argument: id") == true)
        XCTAssertEqual(log.preflightCount, 0)
        XCTAssertEqual(log.scriptCount, 0)
    }

    func testCancellationAfterPreflightStartsPreventsNewScriptExecution() async {
        let log = NotesExecutionLog()
        let preflightStarted = expectation(description: "permission preflight started")
        let releasePreflight = NotesTestSuspension()
        let provider = NotesProvider(
            permissionPreflight: {
                log.recordPreflight()
                preflightStarted.fulfill()
                await releasePreflight.wait()
                // Model an underlying API that finishes successfully despite task cancellation.
                return AutomationPermission.Status(state: "authorized", message: nil)
            },
            scriptExecution: { _ in
                log.recordScript()
                return .success("unexpected")
            }
        )

        let operation = Task {
            await provider.search(input: ["query": .string("test")])
        }

        await fulfillment(of: [preflightStarted], timeout: 1)
        operation.cancel()
        releasePreflight.release()
        let response = await operation.value

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.localizedCaseInsensitiveContains("cancelled") == true)
        XCTAssertEqual(log.preflightCount, 1)
        XCTAssertEqual(log.scriptCount, 0)
    }

    func testCancelledPreflightStatusPreventsNewScriptExecution() async {
        let log = NotesExecutionLog()
        let provider = NotesProvider(
            permissionPreflight: {
                log.recordPreflight()
                return AutomationPermission.Status(
                    state: "cancelled",
                    message: "Automation permission check was cancelled."
                )
            },
            scriptExecution: { _ in
                log.recordScript()
                return .success("unexpected")
            }
        )

        let response = await provider.read(input: ["id": .string("note-id")])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.localizedCaseInsensitiveContains("cancelled") == true)
        XCTAssertEqual(log.preflightCount, 1)
        XCTAssertEqual(log.scriptCount, 0)
    }

    func testAuthorizedPreflightRunsOnlyTheInjectedScriptExecutor() async {
        let log = NotesExecutionLog()
        let provider = NotesProvider(
            permissionPreflight: {
                log.recordPreflight()
                return AutomationPermission.Status(state: "authorized", message: nil)
            },
            scriptExecution: { source in
                log.recordScript(source: source)
                return .success("")
            }
        )

        let response = await provider.search(input: ["query": .string("test")])

        XCTAssertTrue(response.ok)
        XCTAssertEqual(log.preflightCount, 1)
        XCTAssertEqual(log.scriptCount, 1)
        XCTAssertTrue(log.lastScript?.contains("tell application \"Notes\"") == true)
    }

    func testOversizedQueryAndIDFailBeforePermissionPreflight() async {
        let log = NotesExecutionLog()
        let provider = makeProvider(log: log)

        let search = await provider.search(input: [
            "query": .string(String(repeating: "q", count: NotesProvider.maximumQueryUTF8Bytes + 1))
        ])
        let read = await provider.read(input: [
            "id": .string(String(repeating: "i", count: NotesProvider.maximumIdentifierUTF8Bytes + 1))
        ])

        XCTAssertFalse(search.ok)
        XCTAssertFalse(read.ok)
        XCTAssertEqual(log.preflightCount, 0)
        XCTAssertEqual(log.scriptCount, 0)
    }

    func testHostileScriptFieldsAreBoundedBeforeResponseEncoding() async throws {
        let hostile = String(repeating: "\u{0001}", count: 100_000)
        let row = "id\t\(hostile)\t\(hostile)\t\(hostile)\t\(hostile)\tfalse\n"
        let provider = NotesProvider(
            permissionPreflight: {
                AutomationPermission.Status(state: "authorized", message: nil)
            },
            scriptExecution: { _ in .success(row) }
        )

        let response = await provider.search(input: ["query": .string("bounded")])
        let encoded = try M3JSON.makeEncoder().encode(response)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.items[0].metadata["content_truncated"], "true")
        XCTAssertLessThanOrEqual(
            response.items[0].title.utf8.count,
            NotesProvider.maximumReturnedTitleUTF8Bytes
        )
        XCTAssertLessThan(encoded.count, LocalHTTPResponseParser.maximumBodyBytes)
    }

    func testOversizedScriptResultFailsClosed() async {
        let provider = NotesProvider(
            permissionPreflight: {
                AutomationPermission.Status(state: "authorized", message: nil)
            },
            scriptExecution: { _ in
                .success(String(repeating: "x", count: NotesProvider.maximumScriptOutputUTF8Bytes + 1))
            }
        )

        let response = await provider.search(input: [:])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("response work limit") == true)
    }

    private func makeProvider(log: NotesExecutionLog) -> NotesProvider {
        NotesProvider(
            permissionPreflight: {
                log.recordPreflight()
                return AutomationPermission.Status(state: "authorized", message: nil)
            },
            scriptExecution: { source in
                log.recordScript(source: source)
                return .success("")
            }
        )
    }
}

private final class NotesExecutionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var preflightStorage = 0
    private var scripts: [String] = []

    var preflightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return preflightStorage
    }

    var scriptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scripts.count
    }

    var lastScript: String? {
        lock.lock()
        defer { lock.unlock() }
        return scripts.last
    }

    func recordPreflight() {
        lock.lock()
        preflightStorage += 1
        lock.unlock()
    }

    func recordScript(source: String = "") {
        lock.lock()
        scripts.append(source)
        lock.unlock()
    }
}

private final class NotesTestSuspension: @unchecked Sendable {
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
