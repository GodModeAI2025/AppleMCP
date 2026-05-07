import Foundation
import M3MCPCore

final class LocalMCPService {
    private let calendarProvider = CalendarProvider()
    private let contactsProvider = ContactsProvider()
    private let mailProvider = MailProvider()
    private let remindersProvider = RemindersProvider()
    private let notesProvider = NotesProvider()
    private let photosProvider = PhotosProvider()
    private let appleIntelligenceProvider = AppleIntelligenceProvider()
    private let permissionProvider = PermissionProvider()

    var services: [ServiceHealth] {
        [
            ServiceHealth(name: "Permissions", endpoint: "m3mcp://permissions", mode: "TCC preflight", state: "on-demand"),
            ServiceHealth(name: "Mail", endpoint: "mail://local-index", mode: "Mail local index", state: "on-demand"),
            ServiceHealth(name: "Calendar", endpoint: "eventkit://events", mode: "EventKit", state: "on-demand"),
            ServiceHealth(name: "Contacts / Address Book", endpoint: "contacts://local", mode: "Contacts.framework", state: "on-demand"),
            ServiceHealth(name: "Reminders", endpoint: "eventkit://reminders", mode: "EventKit", state: "on-demand"),
            ServiceHealth(name: "Notes", endpoint: "macos://Notes.app", mode: "AppleScript", state: "on-demand"),
            ServiceHealth(name: "Photos", endpoint: "photos://library", mode: "Photos.framework", state: "on-demand"),
            ServiceHealth(name: "Apple Intelligence", endpoint: "macos://intelligence", mode: "AppleScript/Shortcuts/URL scheme", state: "on-demand")
        ]
    }

    func handle(tool: String, input: [String: JSONValue]) async -> ToolResponse {
        let response: ToolResponse
        switch tool {
        case "source_status":
            response = ToolResponse(
                ok: true,
                source: "M3MCP",
                items: services.map {
                    DataItem(
                        id: $0.name,
                        title: $0.name,
                        subtitle: $0.endpoint,
                        kind: "source_status",
                        source: $0.mode,
                        preview: $0.state,
                        metadata: ["endpoint": $0.endpoint, "mode": $0.mode, "state": $0.state]
                    )
                }
            )
        case "permissions_status":
            response = await permissionProvider.status()
        case "permissions_request":
            response = await permissionProvider.requestAll()
        case "permissions_open_settings":
            response = await permissionProvider.openSettings(input: input)
        case "calendar_search":
            response = await calendarProvider.search(input: input)
        case "contacts_search":
            response = await contactsProvider.search(input: input)
        case "mail_search":
            response = await mailProvider.search(input: input)
        case "mail_read":
            response = await mailProvider.read(input: input)
        case "reminders_search":
            response = await remindersProvider.search(input: input)
        case "notes_search":
            response = await notesProvider.search(input: input)
        case "notes_read":
            response = await notesProvider.read(input: input)
        case "photos_search":
            response = await photosProvider.search(input: input)
        case "photos_albums":
            response = await photosProvider.getAlbums(input: input)
        case "ai_writing_tools":
            response = await appleIntelligenceProvider.writingTool(input: input)
        case "ai_translate":
            response = await appleIntelligenceProvider.translate(input: input)
        case "ai_image_playground":
            response = await appleIntelligenceProvider.imagePlayground(input: input)
        default:
            response = ToolResponse(ok: false, source: "M3MCP", message: "Unknown tool: \(tool)")
        }

        return response
    }
}
