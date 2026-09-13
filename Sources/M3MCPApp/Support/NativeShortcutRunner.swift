import AppKit
import Foundation
import ScriptingBridge

@objc private protocol LocalMCPShortcutsApplication {
    @objc optional var shortcuts: SBElementArray { get }
}
@objc private protocol LocalMCPShortcut {
    @objc optional func run(withInput: Any?) -> Any?
}
extension SBApplication: LocalMCPShortcutsApplication {}
extension SBObject: LocalMCPShortcut {}

/// Apple's sandbox-compatible Shortcuts Events interface. Values are typed event parameters,
/// never interpolated into executable script source. The caller still enforces tool opt-in/approval.
enum NativeShortcutRunner {
    private final class EventErrors: NSObject, SBApplicationDelegate {
        var error: Error?
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
            self.error = error
            return nil
        }
    }

    static func run(named name: String, jsonInput: Data, timeout: TimeInterval) async -> Result<String, ShortcutRunner.Failure> {
        guard let input = String(data: jsonInput, encoding: .utf8) else {
            return .failure(.init(message: "Shortcut input was not valid UTF-8."))
        }
        let boundedTimeout = timeout.isFinite ? min(max(timeout, 1), 300) : 60
        let result = await AppleScriptRunner.runNativeOperation(timeout: boundedTimeout) {
            guard let app = SBApplication(bundleIdentifier: "com.apple.shortcuts.events") else {
                return .failure(.init(message: "Shortcuts Events is unavailable on this Mac."))
            }
            let errors = EventErrors()
            app.delegate = errors
            app.timeout = Int(ceil(boundedTimeout * 60))
            app.sendMode = AESendMode(kAEWaitReply | kAENeverInteract)
            guard let shortcuts = (app as LocalMCPShortcutsApplication).shortcuts,
                  let shortcut = shortcuts.object(withName: name) as? LocalMCPShortcut else {
                return .failure(.init(message: errors.error?.localizedDescription ?? "The configured Shortcut could not be found."))
            }
            let output = shortcut.run?(withInput: input)
            if let error = errors.error { return .failure(.init(message: error.localizedDescription)) }
            switch decodeOutput(output) {
            case .success(let text): return .success(text)
            case .failure(let error): return .failure(.init(message: error.message))
            }
        }
        return result.mapError { .init(message: $0.message) }
    }

    static func decodeOutput(_ value: Any?) -> Result<String, ShortcutRunner.Failure> {
        guard let text = value as? String else {
            return .failure(.init(message: "Shortcut must return plain text."))
        }
        guard text.utf8.count <= 1_048_576 else {
            return .failure(.init(message: "Shortcut output exceeded the 1 MiB safety limit."))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.init(message: "Shortcut completed without returning text.")) }
        return .success(trimmed)
    }
}
