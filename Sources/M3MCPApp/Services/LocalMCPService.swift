import Foundation
import M3MCPCore

final class LocalMCPService {
    typealias ApprovalHandler = @Sendable (M3MCPToolApprovalRequest) async -> Bool

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
    private let securityPolicy: M3MCPSecurityPolicy
    private let approvalHandler: ApprovalHandler?

    /// Resolve the environment once when the service starts. Tests and trusted in-process callers
    /// can inject a fixed policy without mutating global process state.
    init(
        securityPolicy: M3MCPSecurityPolicy = .fromProcessEnvironment(),
        approvalHandler: ApprovalHandler? = nil
    ) {
        self.securityPolicy = securityPolicy
        self.approvalHandler = approvalHandler
    }

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
            ServiceHealth(name: "Apple Intelligence", endpoint: "macos://intelligence", mode: "ImageCreator + explicitly enabled user Shortcuts", state: "on-demand"),
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
        guard !Task.isCancelled else {
            return cancellationResponse(tool: tool)
        }

        guard let toolName = M3MCPToolName(rawValue: tool) else {
            return ToolResponse(ok: false, source: "M3MCP", message: "Unknown tool: \(tool)")
        }

        // The app service is an independent authorization boundary: trusted in-process callers and
        // the private HTTP endpoint do not get to rely on bridge-side validation. Reject schema
        // smuggling before launch-policy checks, native approval UI, or any provider call.
        if let validationError = M3MCPToolArgumentPolicy
            .forTool(toolName)
            .validationError(for: input, tool: toolName) {
            return ToolResponse(
                ok: false,
                source: "M3MCP Argument Validation",
                message: validationError.clientMessage
            )
        }

        guard securityPolicy.allows(toolName) else {
            let variable = M3MCPSecurityPolicy.requiredEnvironmentVariable(for: toolName)
                ?? "an explicit launch policy"
            return ToolResponse(
                ok: false,
                source: "M3MCP Security Policy",
                message: "Tool '\(tool)' is disabled by the default-safe policy. Set \(variable)=1 before launching M3MCP to opt in."
            )
        }

        // Do not enter an approval flow for a request whose transport has already disappeared.
        guard !Task.isCancelled else {
            return cancellationResponse(tool: tool)
        }

        if M3MCPInteractiveApproval.requiresApproval(for: toolName) {
            guard let approvalHandler else {
                return ToolResponse(
                    ok: false,
                    source: "M3MCP Interactive Approval",
                    message: "Tool '\(tool)' requires explicit local approval for every call, but no approval UI is available. Request denied."
                )
            }

            let request = M3MCPToolApprovalRequest(tool: toolName, input: input)
            let approved = await approvalHandler(request)
            // Cancellation wins over an approval result. In particular, a late click cannot start a
            // mutation after the requesting bridge has disconnected.
            guard !Task.isCancelled else {
                return cancellationResponse(tool: tool)
            }
            guard approved else {
                return ToolResponse(
                    ok: false,
                    source: "M3MCP Interactive Approval",
                    message: "Tool '\(tool)' was not approved in the M3MCP app. No action was performed."
                )
            }
        }

        // This is the last common gate before provider dispatch. Destructive and open-world
        // providers repeat the check immediately before their own external/irreversible call.
        guard !Task.isCancelled else {
            return cancellationResponse(tool: tool)
        }

        let response: ToolResponse
        switch toolName {
        case .sourceStatus:
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
        case .permissionsStatus:
            response = await permissionProvider.status()
        case .permissionsRequest:
            response = await permissionProvider.requestAll()
        case .permissionsOpenSettings:
            response = await permissionProvider.openSettings(input: input)
        case .calendarSearch:
            response = await calendarProvider.search(input: input)
        case .calendarReadEvent:
            response = await calendarProvider.readEvent(input: input)
        case .calendarListCalendars:
            response = await calendarProvider.listCalendars(input: input)
        case .calendarCreateEvent:
            response = await calendarProvider.createEvent(input: input)
        case .calendarUpdateEvent:
            response = await calendarProvider.updateEvent(input: input)
        case .calendarDeleteEvent:
            response = await calendarProvider.deleteEvent(input: input)
        case .calendarCreateCalendar:
            response = await calendarProvider.createCalendar(input: input)
        case .calendarDeleteCalendar:
            response = await calendarProvider.deleteCalendar(input: input)
        case .contactsSearch:
            response = await contactsProvider.search(input: input)
        case .mailSearch:
            response = await mailProvider.search(input: input)
        case .mailRead:
            response = await mailProvider.read(input: input)
        case .mailListMailboxes:
            response = await mailProvider.listMailboxes(input: input)
        case .remindersSearch:
            response = await remindersProvider.search(input: input)
        case .notesSearch:
            response = await notesProvider.search(input: input)
        case .notesRead:
            response = await notesProvider.read(input: input)
        case .photosSearch:
            response = await photosProvider.search(input: input)
        case .photosAlbums:
            response = await photosProvider.getAlbums(input: input)
        case .voiceMemosSearch:
            response = await voiceMemosProvider.search(input: input)
        case .voiceMemosRead:
            response = await voiceMemosProvider.read(input: input)
        case .voiceMemosTranscript:
            response = await voiceMemosProvider.transcript(input: input)
        case .voiceMemosAudio:
            response = await voiceMemosProvider.audio(input: input)
        case .voiceMemosTranscribe:
            response = await voiceMemosProvider.transcribe(input: input)
        case .aiSummarize:
            response = await foundationModelsProvider.summarize(input: input)
        case .aiWritingTools:
            response = await appleIntelligenceProvider.writingTool(input: input)
        case .aiTranslate:
            response = await appleIntelligenceProvider.translate(input: input)
        case .aiImagePlayground:
            response = await appleIntelligenceProvider.imagePlayground(input: input)
        }

        return response
    }

    private func cancellationResponse(tool: String) -> ToolResponse {
        ToolResponse(
            ok: false,
            source: "M3MCP Cancellation",
            message: "Tool '\(tool)' was cancelled because its client disconnected. No new action was started after cancellation."
        )
    }
}
