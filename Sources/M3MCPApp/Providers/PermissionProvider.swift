import AppKit
import Contacts
import EventKit
import Foundation
import M3MCPCore
import Photos
import Speech

final class PermissionProvider {
    typealias SettingsOpener = @MainActor (URL) -> Bool
    typealias AppActivator = @MainActor () -> Void

    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    private let settingsOpener: SettingsOpener
    private let appActivator: AppActivator

    init(
        settingsOpener: @escaping SettingsOpener = { NSWorkspace.shared.open($0) },
        appActivator: @escaping AppActivator = {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.settingsOpener = settingsOpener
        self.appActivator = appActivator
    }

    func status() async -> ToolResponse {
        let calendar = calendarStatusItem()
        let contacts = contactsStatusItem()
        let reminders = remindersStatusItem()
        let mail = mailLocalStoreStatusItem()
        let notes = await notesAutomationStatusItem(prompt: false)
        let photos = photosStatusItem()
        let voiceMemos = voiceMemosStoreStatusItem()
        let speech = await speechRecognitionStatusItem(prompt: false)

        return ToolResponse(
            ok: true,
            source: "Permissions",
            items: [calendar, contacts, reminders, mail, notes, photos, voiceMemos, speech]
        )
    }

    func requestAll() async -> ToolResponse {
        let run = await PermissionRequestSequence.run([
            { await self.requestCalendar() },
            { await self.requestContacts() },
            { await self.requestReminders() },
            { self.mailLocalStoreStatusItem() },
            { await self.notesAutomationStatusItem(prompt: true) },
            { await self.requestPhotos() },
            { self.voiceMemosStoreStatusItem() },
            { await self.requestSpeechRecognition() }
        ])
        guard !run.cancelled else {
            return ToolResponse(
                ok: false,
                source: "Permissions",
                items: run.items,
                message: "Permission request was cancelled. No further permission prompt or settings action was started."
            )
        }

        let items = run.items
        let required = items.filter { $0.metadata["required"] == "true" }
        let ok = required.allSatisfy { $0.metadata["state"] == "authorized" }

        return ToolResponse(
            ok: ok,
            source: "Permissions",
            items: items,
            message: ok ? "Required permissions are available." : "Some required permissions are still missing."
        )
    }

    @MainActor
    func openSettings(input: [String: JSONValue]) -> ToolResponse {
        guard !Task.isCancelled else {
            return ToolResponse(
                ok: false,
                source: "Permissions",
                message: "Opening System Settings was cancelled."
            )
        }
        let pane = input.string("pane", default: "privacy")
        let urlString: String

        switch pane {
        case "calendar":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case "contacts":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        case "automation", "notes":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case "mail", "files", "full_disk_access":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case "reminders":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case "photos":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        case "voice_memos", "voicememos":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case "speech", "speech_recognition":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        default:
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let url = URL(string: urlString) else {
            return ToolResponse(ok: false, source: "Permissions", message: "Invalid System Settings URL.")
        }

        // Re-check after the actor hop and immediately next to the UI side effect. Cancellation
        // while this task waited for MainActor must not open a settings pane afterward.
        guard !Task.isCancelled else {
            return ToolResponse(
                ok: false,
                source: "Permissions",
                message: "Opening System Settings was cancelled."
            )
        }
        let opened = settingsOpener(url)
        return ToolResponse(
            ok: opened,
            source: "Permissions",
            message: opened ? "Opened System Settings." : "Could not open System Settings."
        )
    }

    private func calendarStatusItem() -> DataItem {
        let status = EKEventStore.authorizationStatus(for: .event)
        let state = eventKitState(status)
        return permissionItem(
            id: "calendar",
            title: "Calendar",
            endpoint: "eventkit://events",
            state: state,
            required: true,
            rawState: state
        )
    }

    private func remindersStatusItem() -> DataItem {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let state = eventKitState(status)
        return permissionItem(
            id: "reminders",
            title: "Reminders",
            endpoint: "eventkit://reminders",
            state: state,
            required: true
        )
    }

    private func photosStatusItem() -> DataItem {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let state: String
        switch status {
        case .authorized, .limited: state = "authorized"
        case .notDetermined: state = "not_determined"
        case .denied, .restricted: state = "denied"
        @unknown default: state = "unknown"
        }
        return permissionItem(
            id: "photos",
            title: "Photos",
            endpoint: "photos://library",
            state: state,
            required: true
        )
    }

    private func contactsStatusItem() -> DataItem {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        let state = contactsState(status)
        return permissionItem(
            id: "contacts",
            title: "Contacts",
            endpoint: "contacts://local",
            state: state,
            required: true,
            rawState: state
        )
    }

    @MainActor
    private func requestReminders() async -> DataItem {
        guard activateForPermissionPrompt() else {
            return cancelledPermissionItem(
                id: "reminders",
                title: "Reminders",
                endpoint: "eventkit://reminders",
                required: true
            )
        }

        do {
            let granted: Bool = try await awaitCancellableCallback { completion in
                self.eventStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        completion(.failure(error))
                    } else {
                        completion(.success(granted))
                    }
                }
            }
            return permissionItem(
                id: "reminders",
                title: "Reminders",
                endpoint: "eventkit://reminders",
                state: granted ? "authorized" : eventKitState(EKEventStore.authorizationStatus(for: .reminder)),
                required: true
            )
        } catch {
            return permissionItem(
                id: "reminders",
                title: "Reminders",
                endpoint: "eventkit://reminders",
                state: "error",
                required: true,
                preview: error.localizedDescription
            )
        }
    }

    @MainActor
    private func requestCalendar() async -> DataItem {
        guard activateForPermissionPrompt() else {
            return cancelledPermissionItem(
                id: "calendar",
                title: "Calendar",
                endpoint: "eventkit://events",
                required: true
            )
        }

        do {
            let granted: Bool = try await awaitCancellableCallback { completion in
                self.eventStore.requestFullAccessToEvents { granted, error in
                    if let error {
                        completion(.failure(error))
                    } else {
                        completion(.success(granted))
                    }
                }
            }

            return permissionItem(
                id: "calendar",
                title: "Calendar",
                endpoint: "eventkit://events",
                state: granted ? "authorized" : eventKitState(EKEventStore.authorizationStatus(for: .event)),
                required: true
            )
        } catch {
            return permissionItem(
                id: "calendar",
                title: "Calendar",
                endpoint: "eventkit://events",
                state: "error",
                required: true,
                preview: error.localizedDescription
            )
        }
    }

    @MainActor
    private func requestContacts() async -> DataItem {
        guard activateForPermissionPrompt() else {
            return cancelledPermissionItem(
                id: "contacts",
                title: "Contacts",
                endpoint: "contacts://local",
                required: true
            )
        }

        do {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .authorized {
                return contactsStatusItem()
            }

            let granted: Bool = try await awaitCancellableCallback { completion in
                self.contactStore.requestAccess(for: .contacts) { granted, error in
                    if let error {
                        completion(.failure(error))
                    } else {
                        completion(.success(granted))
                    }
                }
            }

            return permissionItem(
                id: "contacts",
                title: "Contacts",
                endpoint: "contacts://local",
                state: granted ? "authorized" : contactsState(CNContactStore.authorizationStatus(for: .contacts)),
                required: true
            )
        } catch {
            return permissionItem(
                id: "contacts",
                title: "Contacts",
                endpoint: "contacts://local",
                state: "error",
                required: true,
                preview: error.localizedDescription
            )
        }
    }

    private func mailLocalStoreStatusItem() -> DataItem {
        let status = MailProvider().accessStatus()
        return permissionItem(
            id: "mail_local_store",
            title: "Mail Local Store",
            endpoint: "mail://local-index",
            state: status.state,
            required: true,
            preview: status.message
        )
    }

    private func notesAutomationStatusItem(prompt: Bool) async -> DataItem {
        let status = await AutomationPermission.notes(prompt: prompt)
        if status.isAuthorized {
            return permissionItem(
                id: "notes_automation",
                title: "Notes Automation",
                endpoint: "macos://Notes.app",
                state: "authorized",
                required: true
            )
        }

        return permissionItem(
            id: "notes_automation",
            title: "Notes Automation",
            endpoint: "macos://Notes.app",
            state: status.state,
            required: true,
            preview: status.message ?? "Run permissions_request to trigger the Notes.app Automation permission prompt."
        )
    }

    @MainActor
    private func requestPhotos() async -> DataItem {
        guard activateForPermissionPrompt() else {
            return cancelledPermissionItem(
                id: "photos",
                title: "Photos",
                endpoint: "photos://library",
                required: true
            )
        }

        // PhotoKit has no read-only access level for fetching the existing library. `.addOnly`
        // cannot support this project's read APIs, so the framework-level request is `.readWrite`
        // while the exposed tools remain strictly non-mutating.
        let status: PHAuthorizationStatus
        do {
            status = try await awaitCancellableCallback { completion in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    completion(.success(status))
                }
            }
        } catch is CancellationError {
            return permissionItem(
                id: "photos",
                title: "Photos",
                endpoint: "photos://library",
                state: "cancelled",
                required: true,
                preview: "Photos permission request was cancelled."
            )
        } catch {
            return permissionItem(
                id: "photos",
                title: "Photos",
                endpoint: "photos://library",
                state: "error",
                required: true,
                preview: error.localizedDescription
            )
        }
        let state: String
        switch status {
        case .authorized, .limited:
            state = "authorized"
        case .notDetermined:
            state = "not_determined"
        case .denied, .restricted:
            state = "denied"
        @unknown default:
            state = "unknown"
        }

        return permissionItem(
            id: "photos",
            title: "Photos",
            endpoint: "photos://library",
            state: state,
            required: true
        )
    }



    private func voiceMemosStoreStatusItem() -> DataItem {
        let status = VoiceMemosProvider().accessStatus()
        return permissionItem(
            id: "voice_memos_store",
            title: "Voice Memos Store",
            endpoint: "voicememos://local-store",
            state: status.state,
            required: false,
            preview: status.message
        )
    }

    private func speechRecognitionStatusItem(prompt: Bool) async -> DataItem {
        let state = await LegacySpeechRecognizer.authorizationState(prompt: prompt)
        let hint = state == "authorized"
            ? nil
            : "Only needed for voicememos_transcribe. Stored Voice Memos transcripts are read without it."
        return permissionItem(
            id: "speech_recognition",
            title: "Speech Recognition",
            endpoint: "speech://recognizer",
            state: state,
            required: false,
            preview: hint
        )
    }

    @MainActor
    private func requestSpeechRecognition() async -> DataItem {
        guard activateForPermissionPrompt() else {
            return cancelledPermissionItem(
                id: "speech_recognition",
                title: "Speech Recognition",
                endpoint: "speech://recognizer",
                required: false
            )
        }
        return await speechRecognitionStatusItem(prompt: true)
    }

    /// Cancellation-aware MainActor side-effect boundary shared by every explicit TCC request.
    /// Internal visibility provides a deterministic test seam without invoking a real framework
    /// prompt or activating the application during the test suite.
    @MainActor
    func activateForPermissionPrompt() -> Bool {
        guard !Task.isCancelled else { return false }
        appActivator()
        return true
    }

    private func cancelledPermissionItem(
        id: String,
        title: String,
        endpoint: String,
        required: Bool
    ) -> DataItem {
        permissionItem(
            id: id,
            title: title,
            endpoint: endpoint,
            state: "cancelled",
            required: required,
            preview: "Permission request was cancelled before opening system UI."
        )
    }

    /// `rawState` is the framework's own answer, reported alongside `state` for callers that need
    /// to distinguish the underlying TCC result from any future presentation-layer mapping.
    private func permissionItem(
        id: String,
        title: String,
        endpoint: String,
        state: String,
        required: Bool,
        preview: String? = nil,
        rawState: String? = nil
    ) -> DataItem {
        var metadata: [String: String] = [
            "endpoint": endpoint,
            "state": state,
            "required": String(required)
        ]
        if let rawState {
            metadata["raw_state"] = rawState
        }

        return DataItem(
            id: id,
            title: title,
            subtitle: endpoint,
            kind: "permission",
            source: "Permissions",
            preview: preview ?? state,
            metadata: metadata
        )
    }

    private func eventKitState(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess:
            return "authorized"
        case .writeOnly:
            return "write_only"
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        @unknown default:
            return "unknown"
        }
    }

    private func contactsState(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .limited:
            return "limited"
        @unknown default:
            return "unknown"
        }
    }

    private func automationState(from message: String) -> String {
        let lower = message.localizedLowercase
        if lower.contains("not authorized") || lower.contains("nicht berechtigt") || lower.contains("not allowed") {
            return "denied"
        }
        if lower.contains("user canceled") || lower.contains("abgebrochen") {
            return "not_determined"
        }
        return "error"
    }
}

/// Runs permission stages sequentially and stops before the next stage after task cancellation.
///
/// TCC callback APIs do not consistently resume or dismiss their system prompt when a Swift task is
/// cancelled. The prompt already in flight may therefore finish normally, but disconnecting an MCP
/// client must not cascade into *new* prompts for the remaining services.
enum PermissionRequestSequence {
    static func run<Value>(
        _ stages: [() async -> Value]
    ) async -> (items: [Value], cancelled: Bool) {
        var items: [Value] = []
        items.reserveCapacity(stages.count)

        for stage in stages {
            guard !Task.isCancelled else {
                return (items, true)
            }
            items.append(await stage())
        }

        return (items, Task.isCancelled)
    }
}
