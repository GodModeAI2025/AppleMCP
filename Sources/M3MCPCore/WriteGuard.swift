import Foundation

/// Which tools take two steps, and what the first step answers with.
///
/// Sits in M3MCPCore rather than beside the providers for the same reason `LocalHTTPServer` does:
/// the bridge answers `tools/list` out of its own catalog without ever asking the app, so a schema
/// that declares `confirm_token` proves nothing about what the socket does. From here the rule can
/// be driven from a test that speaks to the socket.
public struct WriteGuard: Sendable {
    /// Every tool that changes the user's calendar. Reads are not listed and are not affected.
    public static let calendarWriteTools: Set<String> = [
        "calendar_create_event",
        "calendar_update_event",
        "calendar_delete_event",
        "calendar_create_calendar",
        "calendar_delete_calendar"
    ]

    public let tools: Set<String>
    public let confirmation: WriteConfirmation

    public init(tools: Set<String> = WriteGuard.calendarWriteTools, confirmation: WriteConfirmation = WriteConfirmation()) {
        self.tools = tools
        self.confirmation = confirmation
    }

    /// What the first call gets back. The caller fills in `preview` with whatever it can resolve —
    /// the current state of the event about to be changed, say — and the rest is the same everywhere.
    public struct Challenge: Sendable {
        public let tool: String
        public let token: String
        public let expiresAt: Date
        public let verdict: WriteConfirmation.Verdict
        public let arguments: [String: JSONValue]

        public func response(preview: [DataItem] = []) -> ToolResponse {
            var meta: [String: String] = [
                "confirm_required": "true",
                "confirm_token": token,
                "confirm_expires_at": ISO8601DateFormatter().string(from: expiresAt),
                "confirm_argument": WriteConfirmation.argumentName,
                "tool": tool
            ]
            for (key, value) in arguments where key != WriteConfirmation.argumentName {
                meta["argument_\(key)"] = value.canonicalText
            }

            return ToolResponse(
                ok: false,
                source: "EventKit",
                items: preview,
                message: Self.message(for: verdict, tool: tool, token: token),
                meta: meta
            )
        }

        private static func message(for verdict: WriteConfirmation.Verdict, tool: String, token: String) -> String {
            let repeatCall = "Nothing has been written. To go ahead, call \(tool) again with the same "
                + "arguments plus \"\(WriteConfirmation.argumentName)\": \"\(token)\". "
                + "Changing any argument invalidates the token, and it expires after five minutes."

            switch verdict {
            case .missing:
                return "\(tool) changes the user's calendar and takes two steps. \(repeatCall)"
            case .expired:
                return "That confirmation token has expired. \(repeatCall)"
            case .mismatched:
                return "That confirmation token was issued for different arguments, so it does not "
                    + "confirm this call. \(repeatCall)"
            case .malformed:
                return "That confirmation token is not readable. \(repeatCall)"
            case .valid:
                return repeatCall
            }
        }
    }

    public enum Outcome: Sendable {
        /// Go ahead, with `confirm_token` stripped so no provider has to know about it.
        case execute([String: JSONValue])
        case challenge(Challenge)
    }

    public func evaluate(tool: String, input: [String: JSONValue], now: Date = Date()) -> Outcome {
        guard tools.contains(tool) else {
            return .execute(input)
        }

        let presented = input[WriteConfirmation.argumentName]?.stringValue
        let verdict = confirmation.verify(token: presented, tool: tool, input: input, now: now)

        guard verdict != .valid else {
            var cleaned = input
            cleaned.removeValue(forKey: WriteConfirmation.argumentName)
            return .execute(cleaned)
        }

        let issued = confirmation.issue(tool: tool, input: input, now: now)
        return .challenge(
            Challenge(
                tool: tool,
                token: issued.token,
                expiresAt: issued.expiresAt,
                verdict: verdict,
                arguments: input
            )
        )
    }
}
