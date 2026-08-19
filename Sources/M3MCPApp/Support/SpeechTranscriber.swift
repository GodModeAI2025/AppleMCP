import Foundation
import Speech

/// On-device speech recognition for recordings that carry no stored transcript.
///
/// The recognition request runs inside M3MCPApp so macOS attributes the Speech Recognition
/// permission to the signed app bundle instead of the MCP bridge process.
enum SpeechTranscriber {
    struct Result {
        let text: String
        let segments: [VoiceMemoTranscript.Segment]
        let locale: String
        let onDevice: Bool
    }

    struct Failure: Error {
        let state: String
        let message: String

        init(state: String, message: String) {
            self.state = state
            self.message = message
        }
    }

    static let defaultTimeout: TimeInterval = 300

    /// Current Speech Recognition permission state, optionally triggering the system prompt.
    static func authorizationState(prompt: Bool) async -> String {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard prompt, status == .notDetermined else {
            return state(for: status)
        }

        let updated: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return state(for: updated)
    }

    static func transcribe(url: URL, languageCode: String, timeout: TimeInterval = defaultTimeout) async throws -> Result {
        let permission = await authorizationState(prompt: true)
        guard permission == "authorized" else {
            throw Failure(
                state: permission,
                message: "Speech Recognition is not authorized for M3MCP. Run permissions_request, or grant access in System Settings > Privacy & Security > Speech Recognition."
            )
        }

        let locale = Locale(identifier: languageCode)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw Failure(state: "unavailable", message: "No speech recognizer exists for locale \(languageCode).")
        }

        guard recognizer.isAvailable else {
            throw Failure(
                state: "unavailable",
                message: "The speech recognizer for \(languageCode) is not available. Install the language in System Settings > Accessibility > Voice Control, then retry."
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        // Keep audio on the machine whenever macOS can recognize this locale locally.
        let onDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice

        let gate = SingleUseGate()
        let taskBox = RecognitionTaskBox()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
            let timeoutWork = DispatchWorkItem {
                guard gate.claim() else { return }
                taskBox.task?.cancel()
                continuation.resume(
                    throwing: Failure(
                        state: "timeout",
                        message: "Speech recognition did not finish within \(Int(timeout)) seconds."
                    )
                )
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            taskBox.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard gate.claim() else { return }
                    timeoutWork.cancel()
                    continuation.resume(throwing: Failure(state: "error", message: error.localizedDescription))
                    return
                }

                guard let result, result.isFinal else { return }
                guard gate.claim() else { return }
                timeoutWork.cancel()

                let segments = result.bestTranscription.segments.map { segment in
                    VoiceMemoTranscript.Segment(
                        text: segment.substring,
                        start: segment.timestamp,
                        end: segment.timestamp + segment.duration
                    )
                }

                continuation.resume(
                    returning: Result(
                        text: result.bestTranscription.formattedString,
                        segments: segments,
                        locale: locale.identifier,
                        onDevice: onDevice
                    )
                )
            }
        }
    }

    private static func state(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "not_determined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
}

/// Guards a continuation so the recognition callback and the timeout cannot both resume it.
private final class SingleUseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used {
            return false
        }
        used = true
        return true
    }
}

private final class RecognitionTaskBox: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
}
