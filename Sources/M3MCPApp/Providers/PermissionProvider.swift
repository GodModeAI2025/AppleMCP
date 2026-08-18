import AppKit
import Contacts
import EventKit
import Foundation
import M3MCPCore
import Photos

final class PermissionProvider {
    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    private let defaults = UserDefaults.standard

    func status() async -> ToolResponse {
        let calendar = calendarStatusItem()
        let contacts = contactsStatusItem()
        let reminders = remindersStatusItem()
        let mail = mailLocalStoreStatusItem()
        let notes = await notesAutomationStatusItem(prompt: false)
        let photos = photosStatusItem()
        let voiceMemos = voiceMemosStoreStatusItem()

        return ToolResponse(ok: true, source: "Permissions", items: [calendar, contacts, reminders, mail, notes, photos, voiceMemos])
    }

    func requestAll() async -> ToolResponse {
        let calendar = await requestCalendar()
        let contacts = await requestContacts()
        let reminders = await requestReminders()
        let mail = mailLocalStoreStatusItem()
        let notes = await notesAutomationStatusItem(prompt: true)
        let photos = await requestPhotos()
        // Full Disk Access cannot be requested programmatically, so this reports state the same way
        // `mail` does. Listing it keeps requestAll in step with status().
        let voiceMemos = voiceMemosStoreStatusItem()

        let items = [calendar, contacts, reminders, mail, notes, photos, voiceMemos]
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
        let pane = input.string("pane", default: "privacy")
        let urlString: String

        switch pane {
        case "calendar":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case "contacts":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        case "automation", "notes":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case "mail", "files", "full_disk_access", "voicememos":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case "reminders":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case "photos":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        default:
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let url = URL(string: urlString) else {
            return ToolResponse(ok: false, source: "Permissions", message: "Invalid System Settings URL.")
        }

        let opened = NSWorkspace.shared.open(url)
        return ToolResponse(
            ok: opened,
            source: "Permissions",
            message: opened ? "Opened System Settings." : "Could not open System Settings."
        )
    }

    private func calendarStatusItem() -> DataItem {
        let status = EKEventStore.authorizationStatus(for: .event)
        let state = eventKitState(status)
        let effectiveState = verifiedState(
            key: "permission.calendar.verified",
            state: state,
            canUseLastVerified: readableCalendarAccessLooksAvailable()
        )
        return permissionItem(
            id: "calendar",
            title: "Calendar",
            endpoint: "eventkit://events",
            state: effectiveState,
            required: true
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
        let effectiveState = verifiedState(
            key: "permission.contacts.verified",
            state: state,
            canUseLastVerified: false
        )
        return permissionItem(
            id: "contacts",
            title: "Contacts",
            endpoint: "contacts://local",
            state: effectiveState,
            required: true
        )
    }

    @MainActor
    private func requestReminders() async -> DataItem {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        do {
            let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            return permissionItem(
                id: "reminders",
                title: "Reminders",
                endpoint: "eventkit://reminders",
                state: granted ? "authorized" : eventKitState(EKEventStore.authorizationStatus(for: .reminder)),
                required: true
            ).savingVerified(defaults: defaults, key: "permission.reminders.verified")
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        do {
            let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }

            return permissionItem(
                id: "calendar",
                title: "Calendar",
                endpoint: "eventkit://events",
                state: granted ? "authorized" : eventKitState(EKEventStore.authorizationStatus(for: .event)),
                required: true
            ).savingVerified(defaults: defaults, key: "permission.calendar.verified")
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        do {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .authorized {
                return contactsStatusItem()
            }

            let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                contactStore.requestAccess(for: .contacts) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }

            return permissionItem(
                id: "contacts",
                title: "Contacts",
                endpoint: "contacts://local",
                state: granted ? "authorized" : contactsState(CNContactStore.authorizationStatus(for: .contacts)),
                required: true
            ).savingVerified(defaults: defaults, key: "permission.contacts.verified")
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

    private func voiceMemosStoreStatusItem() -> DataItem {
        let status = VoiceMemosProvider().accessStatus()
        return permissionItem(
            id: "voicememos_local_store",
            title: "Voice Memos Local Store",
            endpoint: "voicememos://local-store",
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
            ).savingVerified(defaults: defaults, key: "permission.notes_automation.verified")
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
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



    private func permissionItem(
        id: String,
        title: String,
        endpoint: String,
        state: String,
        required: Bool,
        preview: String? = nil
    ) -> DataItem {
        DataItem(
            id: id,
            title: title,
            subtitle: endpoint,
            kind: "permission",
            source: "Permissions",
            preview: preview ?? state,
            metadata: [
                "endpoint": endpoint,
                "state": state,
                "required": String(required)
            ]
        )
    }

    private func verifiedState(key: String, state: String, canUseLastVerified: Bool) -> String {
        if state == "denied" || state == "restricted" || state == "error" {
            return state
        }

        if state == "authorized" || canUseLastVerified || defaults.bool(forKey: key) {
            return "authorized"
        }

        return state
    }

    private func readableCalendarAccessLooksAvailable() -> Bool {
        !eventStore.calendars(for: .event).isEmpty
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

private extension DataItem {
    func savingVerified(defaults: UserDefaults, key: String) -> DataItem {
        defaults.set(metadata["state"] == "authorized", forKey: key)
        return self
    }
}
