import Darwin
import Foundation
import XCTest
@testable import M3MCPCore

final class BoundedProcessRunnerTests: XCTestCase {
    func testRunsExecutableWithoutShellInterpretation() async throws {
        let forbiddenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("m3mcp-must-not-exist-\(UUID().uuidString)")
        let shellLookingText = "$(touch \(forbiddenURL.path)); `id`; a'b\"c"
        let output = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", shellLookingText]
        )

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.standardOutput, as: UTF8.self), shellLookingText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbiddenURL.path))
        XCTAssertFalse(output.outputWasTruncated)
    }

    func testBoundsCapturedOutput() async throws {
        let output = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%0200d", 1.description],
            maximumOutputBytes: 32
        )

        XCTAssertEqual(output.standardOutput.count, 32)
        XCTAssertTrue(output.outputWasTruncated)
    }

    func testDeliversStandardInputExactlyAndClosesThePipe() async throws {
        let payload = Data([0x00, 0x0A, 0x22, 0x5C, 0x7F, 0xFF])
        let output = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            standardInput: payload,
            timeout: 2,
            maximumOutputBytes: payload.count
        )

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(output.standardOutput, payload)
        XCTAssertTrue(output.standardError.isEmpty)
        XCTAssertFalse(output.outputWasTruncated)
    }

    func testTimesOutAndTerminatesProcess() async {
        do {
            _ = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.05
            )
            XCTFail("Expected timeout")
        } catch let error as BoundedProcessRunner.RunnerError {
            XCTAssertEqual(error, .timedOut(seconds: 1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutIncludesLargeStdinWhenChildNeverReadsIt() async {
        let started = Date()
        do {
            _ = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                standardInput: Data(repeating: 0x41, count: 8 * 1_024 * 1_024),
                timeout: 0.05
            )
            XCTFail("Expected timeout")
        } catch let error as BoundedProcessRunner.RunnerError {
            XCTAssertEqual(error, .timedOut(seconds: 1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testRejectsUnboundedLimitsBeforeLaunching() async {
        do {
            _ = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: [],
                timeout: .greatestFiniteMagnitude,
                maximumOutputBytes: Int.max
            )
            XCTFail("Expected invalid limits")
        } catch let error as BoundedProcessRunner.RunnerError {
            XCTAssertEqual(error, .invalidLimits)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationTerminatesAnAlreadyLaunchedProcessPromptly() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("m3mcp-runner-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidURL) }

        let task = Task {
            try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30",
                    "m3mcp-cancellation-test",
                    pidURL.path
                ],
                timeout: 60
            )
        }

        // The PID file proves cancellation happens after launch, rather than merely exercising the
        // pre-launch Task.checkCancellation path.
        let launchDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidURL.path), Date() < launchDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path), "child process did not launch")

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        let cancelledAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 3)
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "cancelled child process is still alive")
        XCTAssertEqual(errno, ESRCH)
    }
}
