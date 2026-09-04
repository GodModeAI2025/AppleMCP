import Darwin
import Foundation

/// Runs a fixed executable directly, without a shell, while bounding execution time and captured
/// output. Callers remain responsible for deciding whether the executable itself is trusted.
public enum BoundedProcessRunner {
    public struct Output: Equatable, Sendable {
        public let terminationStatus: Int32
        public let standardOutput: Data
        public let standardError: Data
        public let outputWasTruncated: Bool

        public init(
            terminationStatus: Int32,
            standardOutput: Data,
            standardError: Data,
            outputWasTruncated: Bool
        ) {
            self.terminationStatus = terminationStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.outputWasTruncated = outputWasTruncated
        }
    }

    public enum RunnerError: Error, Equatable, LocalizedError, Sendable {
        case invalidLimits
        case launchFailed(String)
        case timedOut(seconds: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidLimits:
                return "Process timeout and output limit must be positive and finite."
            case .launchFailed(let message):
                return "Could not launch process: \(message)"
            case .timedOut(let seconds):
                return "Process timed out after \(seconds) seconds."
            }
        }
    }

    public static func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval = 30,
        maximumOutputBytes: Int = 1_048_576
    ) async throws -> Output {
        guard timeout.isFinite,
              timeout > 0,
              timeout <= 86_400,
              (1...64 * 1_024 * 1_024).contains(maximumOutputBytes) else {
            throw RunnerError.invalidLimits
        }

        let cancellation = ProcessCancellationController()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output = try await Task.detached(priority: .userInitiated) {
                try runBlocking(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput,
                    timeout: timeout,
                    maximumOutputBytes: maximumOutputBytes,
                    cancellation: cancellation
                )
            }.value
            // The detached worker performs blocking pipe drains, so cancellation is conveyed by the
            // shared process controller. Re-check here to surface CancellationError rather than a
            // signal-derived exit status after the child has been terminated.
            try Task.checkCancellation()
            return output
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runBlocking(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        cancellation: ProcessCancellationController
    ) throws -> Output {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let completion = DispatchSemaphore(value: 0)
        let drains = DispatchGroup()
        let output = OutputCollector(limit: maximumOutputBytes)
        let errors = OutputCollector(limit: maximumOutputBytes)

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in completion.signal() }

        do {
            try cancellation.launch(process)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RunnerError.launchFailed(error.localizedDescription)
        }
        defer { cancellation.finished(process) }

        // The deadline covers the complete child interaction, including stdin delivery. Writing a
        // large payload synchronously before starting this clock lets a child that never reads stdin
        // defeat both timeout and structured cancellation by filling the pipe.
        let deadline = DispatchTime.now() + timeout
        // A child can close its read end while the asynchronous writer is still draining. Suppress
        // SIGPIPE on this descriptor so that ordinary EPIPE becomes the caught write error instead
        // of terminating the entire bridge/app process.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            output.consume(outputPipe.fileHandleForReading)
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            errors.consume(errorPipe.fileHandleForReading)
            drains.leave()
        }

        let inputWrite = DispatchGroup()
        inputWrite.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { inputWrite.leave() }
            do {
                if let standardInput, !standardInput.isEmpty {
                    try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                }
                try inputPipe.fileHandleForWriting.close()
            } catch {
                // A process is allowed to close stdin early. Its exit status and stderr provide the
                // actionable result, so this is not promoted over the process outcome.
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        guard completion.wait(timeout: deadline) == .success else {
            process.terminate()
            if completion.wait(timeout: .now() + 1) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 1)
            }
            _ = inputWrite.wait(timeout: .now() + 2)
            _ = drains.wait(timeout: .now() + 2)
            throw RunnerError.timedOut(seconds: max(1, Int(timeout.rounded(.up))))
        }

        _ = inputWrite.wait(timeout: .now() + 2)
        _ = drains.wait(timeout: .now() + 2)
        return Output(
            terminationStatus: process.terminationStatus,
            standardOutput: output.data,
            standardError: errors.data,
            outputWasTruncated: output.wasTruncated || errors.wasTruncated
        )
    }
}

/// Bridges structured-concurrency cancellation into Foundation's blocking `Process` API.
///
/// Launch and cancellation share one lock. If cancellation wins, the process is never launched; if
/// launch wins, cancellation sends TERM and escalates to KILL after one second. The escalation is
/// deliberately bounded and PID-identity checked so it cannot target a later process after this
/// controller has finished.
private final class ProcessCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var process: Process?

    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !cancellationRequested else {
            throw CancellationError()
        }

        self.process = process
        do {
            try process.run()
        } catch {
            self.process = nil
            throw error
        }
    }

    func cancel() {
        let identifier: Int32?

        lock.lock()
        cancellationRequested = true
        if let process, process.isRunning {
            identifier = process.processIdentifier
            process.terminate()
        } else {
            identifier = nil
        }
        lock.unlock()

        guard let identifier else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.forceKillIfStillRunning(identifier: identifier)
        }
    }

    func finished(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    private func forceKillIfStillRunning(identifier: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let process,
              process.processIdentifier == identifier,
              process.isRunning else {
            return
        }
        _ = Darwin.kill(identifier, SIGKILL)
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(min(limit, 64 * 1_024))
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }

    func consume(_ handle: FileHandle) {
        defer { try? handle.close() }
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 8_192), !next.isEmpty else { return }
                chunk = next
            } catch {
                return
            }

            lock.lock()
            let remaining = max(0, limit - storage.count)
            if chunk.count > remaining {
                storage.append(chunk.prefix(remaining))
                truncated = true
            } else {
                storage.append(chunk)
            }
            lock.unlock()
        }
    }
}
