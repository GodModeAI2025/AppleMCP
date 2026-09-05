import Foundation

/// The complete public tool namespace understood by both the MCP bridge and the app dispatcher.
///
/// Keeping these names in Core gives discovery and execution one authoritative vocabulary. A tool
/// added to either side without a Core case is denied rather than silently inheriting an unsafe
/// default.
public enum M3MCPToolName: String, CaseIterable, Sendable {
    case sourceStatus = "source_status"
    case permissionsStatus = "permissions_status"
    case permissionsRequest = "permissions_request"
    case permissionsOpenSettings = "permissions_open_settings"

    case calendarSearch = "calendar_search"
    case calendarReadEvent = "calendar_read_event"
    case calendarListCalendars = "calendar_list_calendars"
    case calendarCreateEvent = "calendar_create_event"
    case calendarUpdateEvent = "calendar_update_event"
    case calendarDeleteEvent = "calendar_delete_event"
    case calendarCreateCalendar = "calendar_create_calendar"
    case calendarDeleteCalendar = "calendar_delete_calendar"
    case calendarUndoWrite = "calendar_undo_write"

    case contactsSearch = "contacts_search"
    case mailSearch = "mail_search"
    case mailListMailboxes = "mail_list_mailboxes"
    case mailRead = "mail_read"
    case remindersSearch = "reminders_search"
    case notesSearch = "notes_search"
    case notesRead = "notes_read"
    case photosSearch = "photos_search"
    case photosAlbums = "photos_albums"
    case voiceMemosSearch = "voicememos_search"
    case voiceMemosRead = "voicememos_read"
    case voiceMemosTranscript = "voicememos_transcript"
    case voiceMemosAudio = "voicememos_audio"
    case voiceMemosTranscribe = "voicememos_transcribe"

    case aiSummarize = "ai_summarize"
    case aiWritingTools = "ai_writing_tools"
    case aiTranslate = "ai_translate"
    case aiImagePlayground = "ai_image_playground"
}

/// Launch-time policy for tools that can mutate user data, display security UI, or invoke arbitrary
/// user-created automations.
///
/// The safe default exposes observation and bounded local processing only. Opt-ins are intentionally
/// supplied by the process environment before launch; there is no MCP tool that can relax this
/// policy at runtime.
public struct M3MCPSecurityPolicy: Equatable, Sendable {
    public enum ToolClassification: String, CaseIterable, Sendable {
        /// Observes local state without changing the source being observed.
        case readOnly
        /// Computes a local result. It may create an app-owned cache or temporary artifact, but does
        /// not mutate the user's source data or invoke user-defined automation.
        case localProcessing
        /// Generates an app-owned local artifact without launching UI or arbitrary automation.
        case localGeneration
        /// Creates, updates, or deletes Calendar data.
        ///
        /// A single event write records what it replaced and can be reversed once through
        /// `calendar_undo_write`. Deleting a calendar cannot: it takes its events with it.
        case calendarMutation
        /// Requests a macOS permission or opens System Settings.
        case permissionUI
        /// Runs a user-defined Shortcut whose network access and side effects cannot be constrained.
        case userShortcut
    }

    public struct Configuration: Equatable, Sendable {
        public var allowCalendarMutations: Bool
        public var allowPermissionUI: Bool
        public var allowUserShortcuts: Bool

        public init(
            allowCalendarMutations: Bool = false,
            allowPermissionUI: Bool = false,
            allowUserShortcuts: Bool = false
        ) {
            self.allowCalendarMutations = allowCalendarMutations
            self.allowPermissionUI = allowPermissionUI
            self.allowUserShortcuts = allowUserShortcuts
        }

        public static let defaultSafe = Configuration()
    }

    /// A catalog-free projection for native UI and diagnostics.
    ///
    /// Tool descriptions and JSON schemas remain bridge concerns, but availability must come from
    /// the same reviewed vocabulary and immutable launch policy that discovery and dispatch use.
    public struct ToolAvailability: Equatable, Identifiable, Sendable {
        public let tool: M3MCPToolName
        public let isEnabled: Bool
        public let requiredEnvironmentVariable: String?

        public var id: String { tool.rawValue }
        public var name: String { tool.rawValue }
        public var endpointPath: String { "/tools/\(tool.rawValue)" }
        public var requiresOptIn: Bool { requiredEnvironmentVariable != nil }
    }

    public static let calendarMutationsEnvironmentVariable = "M3MCP_ENABLE_CALENDAR_MUTATIONS"
    public static let permissionUIEnvironmentVariable = "M3MCP_ENABLE_PERMISSION_UI"
    public static let userShortcutsEnvironmentVariable = "M3MCP_ENABLE_USER_SHORTCUTS"

    public let configuration: Configuration

    public init(configuration: Configuration = .defaultSafe) {
        self.configuration = configuration
    }

    /// Resolves policy once from the launch environment. Only an explicit true token enables a
    /// capability; missing, empty, and malformed values all fail closed.
    public static func fromProcessEnvironment() -> M3MCPSecurityPolicy {
        fromEnvironment(ProcessInfo.processInfo.environment)
    }

    /// Injectable environment resolver used by deterministic tests and non-process callers.
    public static func fromEnvironment(_ environment: [String: String]) -> M3MCPSecurityPolicy {
        M3MCPSecurityPolicy(
            configuration: Configuration(
                allowCalendarMutations: explicitTrue(
                    environment[calendarMutationsEnvironmentVariable]
                ),
                allowPermissionUI: explicitTrue(
                    environment[permissionUIEnvironmentVariable]
                ),
                allowUserShortcuts: explicitTrue(
                    environment[userShortcutsEnvironmentVariable]
                )
            )
        )
    }

    public static var knownToolNames: Set<String> {
        Set(M3MCPToolName.allCases.map(\.rawValue))
    }

    public static func classification(of tool: M3MCPToolName) -> ToolClassification {
        switch tool {
        case .sourceStatus,
             .permissionsStatus,
             .calendarSearch,
             .calendarReadEvent,
             .calendarListCalendars,
             .contactsSearch,
             .mailSearch,
             .mailListMailboxes,
             .mailRead,
             .remindersSearch,
             .notesSearch,
             .notesRead,
             .photosSearch,
             .photosAlbums,
             .voiceMemosSearch,
             .voiceMemosRead,
             .voiceMemosTranscript,
             .voiceMemosAudio:
            return .readOnly

        case .voiceMemosTranscribe,
             .aiSummarize:
            // These transform caller-selected input locally. They do not mutate Calendar or run a
            // user Shortcut, so they remain available in the safe profile.
            return .localProcessing

        case .aiImagePlayground:
            // The current provider calls ImageCreator directly and writes only the generated image
            // to the app's temporary directory. It does not open Image Playground UI or invoke a
            // user-defined Shortcut. Reclassify this if that implementation boundary changes.
            return .localGeneration

        case .calendarCreateEvent,
             .calendarUpdateEvent,
             .calendarDeleteEvent,
             .calendarCreateCalendar,
             .calendarDeleteCalendar,
             .calendarUndoWrite:
            return .calendarMutation

        case .permissionsRequest,
             .permissionsOpenSettings:
            return .permissionUI

        case .aiWritingTools,
             .aiTranslate:
            return .userShortcut
        }
    }

    public static func classification(ofToolNamed name: String) -> ToolClassification? {
        guard let tool = M3MCPToolName(rawValue: name) else { return nil }
        return classification(of: tool)
    }

    public func allows(_ tool: M3MCPToolName) -> Bool {
        switch Self.classification(of: tool) {
        case .readOnly, .localProcessing, .localGeneration:
            return true
        case .calendarMutation:
            return configuration.allowCalendarMutations
        case .permissionUI:
            return configuration.allowPermissionUI
        case .userShortcut:
            return configuration.allowUserShortcuts
        }
    }

    /// Unknown names are denied so a newly added catalog or dispatcher entry cannot bypass policy.
    public func allows(toolNamed name: String) -> Bool {
        guard let tool = M3MCPToolName(rawValue: name) else { return false }
        return allows(tool)
    }

    /// Every reviewed tool exactly once, annotated with its state under this launch policy.
    /// Default-safe callers therefore receive 21 enabled rows plus the ten explicit opt-ins,
    /// without maintaining a second UI catalog.
    public var toolAvailability: [ToolAvailability] {
        M3MCPToolName.allCases.map { tool in
            ToolAvailability(
                tool: tool,
                isEnabled: allows(tool),
                requiredEnvironmentVariable: Self.requiredEnvironmentVariable(for: tool)
            )
        }
    }

    /// Permission request and settings actions are one policy class and must move together in the
    /// native UI. Keeping this derived prevents a button from bypassing or contradicting dispatch.
    public var allowsPermissionUI: Bool {
        allows(.permissionsRequest) && allows(.permissionsOpenSettings)
    }

    public static func requiredEnvironmentVariable(for tool: M3MCPToolName) -> String? {
        switch classification(of: tool) {
        case .readOnly, .localProcessing, .localGeneration:
            return nil
        case .calendarMutation:
            return calendarMutationsEnvironmentVariable
        case .permissionUI:
            return permissionUIEnvironmentVariable
        case .userShortcut:
            return userShortcutsEnvironmentVariable
        }
    }

    private static func explicitTrue(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
