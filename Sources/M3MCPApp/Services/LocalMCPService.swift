import Foundation
import M3MCPCore

final class LocalMCPService {
    private let calendarProvider = CalendarProvider()
    private let contactsProvider = ContactsProvider()
    private let mailProvider = MailProvider()
    private let remindersProvider = RemindersProvider()
    private let notesProvider = NotesProvider()
    private let photosProvider = PhotosProvider()
    private let voiceMemosProvider = VoiceMemosProvider()
    private let appleIntelligenceProvider = AppleIntelligenceProvider()
    private let foundationModelsProvider = FoundationModelsProvider()
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
            ServiceHealth(
                name: "Voice Memos",
                endpoint: "voicememos://local-store",
                mode: "CloudRecordings store + on-device transcription",
                // Reported live rather than as "on-demand": when transcription is unavailable the
                // reason is the useful part, and source_status is where a caller looks for it.
                state: SpeechTranscription.statusDescription
            ),
            ServiceHealth(name: "Apple Intelligence", endpoint: "macos://intelligence", mode: "AppleScript/Shortcuts/URL scheme", state: "on-demand"),
            ServiceHealth(
                name: "Foundation Models",
                endpoint: "macos://foundationmodels",
                mode: "On-device Apple language model",
                // Reported live rather than as "on-demand": when the model is unavailable the reason
                // is the useful part, and source_status is where a caller looks for it.
                state: foundationModelsProvider.statusDescription
            )
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
        case "calendar_read_event":
            response = await calendarProvider.readEvent(input: input)
        case "calendar_list_calendars":
            response = await calendarProvider.listCalendars(input: input)
        case "calendar_create_event":
            response = await calendarProvider.createEvent(input: input)
        case "calendar_update_event":
            response = await calendarProvider.updateEvent(input: input)
        case "calendar_delete_event":
            response = await calendarProvider.deleteEvent(input: input)
        case "calendar_create_calendar":
            response = await calendarProvider.createCalendar(input: input)
        case "calendar_delete_calendar":
            response = await calendarProvider.deleteCalendar(input: input)
        case "contacts_search":
            response = await contactsProvider.search(input: input)
        case "mail_search":
            response = await mailProvider.search(input: input)
        case "mail_read":
            response = await mailProvider.read(input: input)
        case "mail_list_mailboxes":
            response = await mailProvider.listMailboxes(input: input)
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
        case "voicememos_search":
            response = await voiceMemosProvider.search(input: input)
        case "voicememos_read":
            response = await voiceMemosProvider.read(input: input)
        case "voicememos_transcript":
            response = await voiceMemosProvider.transcript(input: input)
        case "voicememos_audio":
            response = await voiceMemosProvider.audio(input: input)
        case "voicememos_transcribe":
            response = await voiceMemosProvider.transcribe(input: input)
        case "ai_summarize":
            response = await foundationModelsProvider.summarize(input: input)
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
