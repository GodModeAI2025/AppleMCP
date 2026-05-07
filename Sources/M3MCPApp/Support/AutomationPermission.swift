import AppKit
import CoreServices
import Foundation

enum AutomationPermission {
    struct Status {
        let state: String
        let message: String?

        var isAuthorized: Bool {
            state == "authorized"
        }
    }

    @MainActor
    static func notes(prompt: Bool) -> Status {
        app(bundleIdentifier: "com.apple.Notes", prompt: prompt)
    }

    @MainActor
    static func app(bundleIdentifier: String, prompt: Bool) -> Status {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let first = determine(bundleIdentifier: bundleIdentifier, prompt: prompt)
        guard first.state == "error", first.message?.contains("-600") == true else {
            return first
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
            Thread.sleep(forTimeInterval: 1)
        }

        return determine(bundleIdentifier: bundleIdentifier, prompt: prompt)
    }

    private static func determine(bundleIdentifier: String, prompt: Bool) -> Status {
        guard let data = bundleIdentifier.data(using: .utf8) else {
            return Status(state: "error", message: "Invalid target bundle identifier.")
        }

        var target = AEAddressDesc()
        let createStatus = data.withUnsafeBytes { bytes in
            AECreateDesc(
                typeApplicationBundleID,
                bytes.baseAddress,
                data.count,
                &target
            )
        }

        guard createStatus == noErr else {
            return Status(state: "error", message: osStatusMessage(OSStatus(createStatus)))
        }

        defer {
            AEDisposeDesc(&target)
        }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(kCoreEventClass),
            AEEventID(kAEGetData),
            prompt
        )

        switch status {
        case noErr:
            return Status(state: "authorized", message: nil)
        case OSStatus(errAEEventWouldRequireUserConsent):
            return Status(state: "not_determined", message: "Automation approval is required.")
        case OSStatus(errAEEventNotPermitted):
            return Status(state: "denied", message: "Automation approval was denied or is blocked by policy.")
        case OSStatus(userCanceledErr):
            return Status(state: "denied", message: "Automation approval was cancelled.")
        default:
            return Status(state: "error", message: osStatusMessage(status))
        }
    }

    private static func osStatusMessage(_ status: OSStatus) -> String {
        let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        return "\(error.localizedDescription) (OSStatus \(status))"
    }
}
