import AppKit
import Foundation

enum AppleScriptRunner {
    struct Failure: Error {
        let message: String
    }

    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let continuation: CheckedContinuation<Result<String, Failure>, Never>

        init(_ continuation: CheckedContinuation<Result<String, Failure>, Never>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<String, Failure>) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            lock.unlock()
            continuation.resume(returning: result)
        }
    }

    static func run(_ source: String, timeout: TimeInterval = 8) async -> Result<String, Failure> {
        await MainActor.run {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        return await withCheckedContinuation { continuation in
            let box = CompletionBox(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                box.finish(execute(source))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.finish(.failure(Failure(message: "AppleScript timed out after \(Int(timeout))s. The target app did not answer its Apple Event interface.")))
            }
        }
    }

    private static func execute(_ source: String) -> Result<String, Failure> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(Failure(message: "Could not compile AppleScript."))
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            return .failure(Failure(message: message))
        }

        return .success(descriptor.stringValue ?? descriptor.description)
    }
}
