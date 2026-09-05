/// Advisory MCP annotations for a tool. These values help a trusted client present risk, but they
/// are never authorization: launch policy and per-call approval remain server-side checks.
public struct M3MCPToolSecurityHints: Equatable, Sendable {
    public let readOnly: Bool
    public let destructive: Bool
    public let idempotent: Bool
    public let openWorld: Bool

    public init(
        readOnly: Bool,
        destructive: Bool,
        idempotent: Bool,
        openWorld: Bool
    ) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
    }

    public static func forTool(_ tool: M3MCPToolName) -> M3MCPToolSecurityHints {
        switch M3MCPSecurityPolicy.classification(of: tool) {
        case .readOnly:
            return M3MCPToolSecurityHints(
                readOnly: true,
                destructive: false,
                idempotent: true,
                openWorld: false
            )

        case .localProcessing:
            // Processing may create or refresh an app-owned cache, so this stays conservatively
            // non-read-only even though it does not mutate the selected Apple data source.
            return M3MCPToolSecurityHints(
                readOnly: false,
                destructive: false,
                idempotent: true,
                openWorld: false
            )

        case .localGeneration:
            return M3MCPToolSecurityHints(
                readOnly: false,
                destructive: false,
                idempotent: false,
                openWorld: false
            )

        case .calendarMutation:
            switch tool {
            case .calendarCreateEvent, .calendarCreateCalendar:
                return M3MCPToolSecurityHints(
                    readOnly: false,
                    destructive: false,
                    idempotent: false,
                    openWorld: true
                )
            case .calendarUpdateEvent, .calendarDeleteEvent, .calendarDeleteCalendar:
                return M3MCPToolSecurityHints(
                    readOnly: false,
                    destructive: true,
                    idempotent: true,
                    openWorld: true
                )
            case .calendarUndoWrite:
                // Destructive because reversing a create removes an event, and because reversing an
                // update overwrites whatever the field holds now. Idempotent because the token is
                // spent on first use: a repeated call reports that it was already undone rather
                // than acting a second time.
                return M3MCPToolSecurityHints(
                    readOnly: false,
                    destructive: true,
                    idempotent: true,
                    openWorld: true
                )
            default:
                // Future policy/catalog drift must fail safely without making tools/list crash.
                return M3MCPToolSecurityHints(
                    readOnly: false,
                    destructive: true,
                    idempotent: false,
                    openWorld: true
                )
            }

        case .permissionUI:
            return M3MCPToolSecurityHints(
                readOnly: false,
                destructive: false,
                idempotent: false,
                openWorld: true
            )

        case .userShortcut:
            // A user-authored Shortcut is intentionally treated as maximally open and potentially
            // destructive because its implementation is outside this server's control.
            return M3MCPToolSecurityHints(
                readOnly: false,
                destructive: true,
                idempotent: false,
                openWorld: true
            )
        }
    }
}
