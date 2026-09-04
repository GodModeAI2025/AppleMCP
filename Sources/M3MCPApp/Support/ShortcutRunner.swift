import Foundation
import M3MCPCore

/// Executes a user-created Shortcut through the fixed system binary. No shell, AppleScript, Python,
/// or caller-controlled command line is involved.
enum ShortcutRunner {
    struct Failure: Error {
        let message: String
    }

    struct ProcessInvocation: Equatable {
        let executableURL: URL
        let arguments: [String]
        let standardInput: Data
        let timeout: TimeInterval
        let maximumOutputBytes: Int
    }

    static func decodeUTF8PlainText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(
        named name: String,
        jsonInput: Data,
        timeout: TimeInterval = 60
    ) async -> Result<String, Failure> {
        guard !Task.isCancelled else {
            return .failure(Failure(message: "Shortcut request was cancelled before launch."))
        }

        let invocation = processInvocation(named: name, jsonInput: jsonInput, timeout: timeout)

        do {
            try Task.checkCancellation()
            let output = try await BoundedProcessRunner.run(
                executableURL: invocation.executableURL,
                arguments: invocation.arguments,
                standardInput: invocation.standardInput,
                timeout: invocation.timeout,
                maximumOutputBytes: invocation.maximumOutputBytes
            )
            try Task.checkCancellation()

            if output.outputWasTruncated {
                return .failure(Failure(message: "Shortcut output exceeded the 1 MiB safety limit."))
            }

            guard let standardOutput = decodeUTF8PlainText(output.standardOutput) else {
                return .failure(Failure(message: "Shortcut output was not valid UTF-8 plain text."))
            }
            let standardError = decodeUTF8PlainText(output.standardError)

            guard output.terminationStatus == 0 else {
                let detail = (standardError?.isEmpty == false ? standardError : standardOutput) ?? ""
                return .failure(Failure(
                    message: detail.isEmpty
                        ? "Shortcut exited with status \(output.terminationStatus)."
                        : detail
                ))
            }
            guard !standardOutput.isEmpty else {
                return .failure(Failure(message: "Shortcut completed without returning text."))
            }
            return .success(standardOutput)
        } catch is CancellationError {
            return .failure(Failure(
                message: "Shortcut request was cancelled. A Shortcut side effect completed before cancellation cannot be rolled back."
            ))
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
    }

    /// `shortcuts run` accepts `-` as the input path, which makes it read stdin. Keeping the JSON on
    /// the already-bounded pipe avoids closing a temporary file and later reopening its mutable path.
    static func processInvocation(
        named name: String,
        jsonInput: Data,
        timeout: TimeInterval
    ) -> ProcessInvocation {
        ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/shortcuts"),
            arguments: [
                "run", name,
                "--input-path", "-",
                "--output-type", "public.utf8-plain-text"
            ],
            standardInput: jsonInput,
            timeout: timeout,
            maximumOutputBytes: 1_048_576
        )
    }
}
