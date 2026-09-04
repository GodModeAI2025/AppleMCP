import Foundation

/// The JSON value shapes advertised and accepted for top-level tool arguments.
///
/// Providers may apply stricter semantic validation (date formats, ranges, identifiers, and so on),
/// but they must never receive a value whose basic JSON shape differs from the public MCP schema.
public enum M3MCPToolArgumentValueType: String, Equatable, Sendable {
    case string
    case integer
    case boolean
    case stringArray

    public var jsonSchemaType: String {
        switch self {
        case .string:
            return "string"
        case .integer:
            return "integer"
        case .boolean:
            return "boolean"
        case .stringArray:
            return "array"
        }
    }

    public var jsonSchemaItemType: String? {
        self == .stringArray ? "string" : nil
    }

    fileprivate func accepts(_ value: JSONValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.boolean, .bool):
            return true
        case (.integer, .number(let number)):
            // Providers consume integer arguments through JSONValue.intValue. Accepting a wider
            // Double here would let an out-of-Int value pass both execution boundaries and then be
            // silently treated as absent/default by the provider.
            return Int(exactly: number) != nil
        case (.stringArray, .array(let values)):
            return values.allSatisfy { value in
                if case .string = value { return true }
                return false
            }
        default:
            return false
        }
    }

    fileprivate var clientDescription: String {
        switch self {
        case .string:
            return "a string"
        case .integer:
            return "an integer"
        case .boolean:
            return "a boolean"
        case .stringArray:
            return "an array of strings"
        }
    }
}

/// A bounded validation failure safe to return through either the MCP bridge or local app service.
public struct M3MCPToolArgumentValidationError: Error, Equatable, Sendable {
    public static let maximumClientMessageBytes = 240

    public let clientMessage: String

    fileprivate init(_ message: String) {
        clientMessage = Self.bounded(message)
    }

    private static func bounded(_ message: String) -> String {
        guard message.utf8.count > maximumClientMessageBytes else { return message }

        var prefix = Data(message.utf8.prefix(maximumClientMessageBytes - 3))
        while !prefix.isEmpty {
            if let text = String(data: prefix, encoding: .utf8) {
                return text + "..."
            }
            prefix.removeLast()
        }
        return "Invalid tool arguments."
    }
}

/// The single execution-side argument contract for every public M3MCP tool.
///
/// The switch in `forTool` is deliberately exhaustive. Adding a tool name therefore cannot inherit
/// an open argument dictionary by default: the compiler requires an explicit reviewed policy.
public struct M3MCPToolArgumentPolicy: Equatable, Sendable {
    public let argumentTypes: [String: M3MCPToolArgumentValueType]
    public let integerRanges: [String: ClosedRange<Int>]
    public let requiredKeys: Set<String>
    /// At least one complete set must be present. This mirrors JSON Schema `anyOf` branches whose
    /// only constraint is `required` (currently used to require a Calendar target).
    public let requiredAlternativeKeySets: [Set<String>]

    public var allowedKeys: Set<String> {
        Set(argumentTypes.keys)
    }

    public static func forTool(_ tool: M3MCPToolName) -> M3MCPToolArgumentPolicy {
        switch tool {
        case .sourceStatus, .permissionsStatus, .permissionsRequest:
            return policy()

        case .permissionsOpenSettings:
            return policy(strings: ["pane"])

        case .calendarSearch:
            return queryPolicy(
                strings: ["calendar"],
                integers: ["start_days", "end_days", "max_candidates"]
            )

        case .calendarReadEvent:
            return policy(strings: ["id"], required: ["id"])

        case .calendarListCalendars:
            return policy(strings: ["query"], booleans: ["writable_only"])

        case .calendarCreateEvent:
            return policy(
                strings: [
                    "title", "start", "end", "calendar", "calendar_id", "location", "notes",
                    "url", "project_slug"
                ],
                integers: ["duration_minutes", "alarm_minutes_before"],
                booleans: ["all_day"],
                required: ["title", "start"],
                requiredAlternatives: [["calendar_id"], ["calendar"]]
            )

        case .calendarUpdateEvent:
            return policy(
                strings: [
                    "id", "title", "start", "end", "location", "notes", "url", "project_slug",
                    "calendar", "calendar_id", "span"
                ],
                integers: ["duration_minutes"],
                booleans: ["all_day"],
                required: ["id"]
            )

        case .calendarDeleteEvent:
            return policy(strings: ["id", "span"], required: ["id"])

        case .calendarCreateCalendar:
            return policy(strings: ["title", "source"], required: ["title"])

        case .calendarDeleteCalendar:
            return policy(strings: ["id", "title"], required: ["id", "title"])

        case .contactsSearch:
            return queryPolicy()

        case .mailSearch:
            return queryPolicy(
                strings: ["mailbox", "match"],
                integers: ["offset", "since_hours", "max_candidates"],
                booleans: [
                    "unread_only", "include_junk", "include_body", "include_recipients",
                    "auto_intent"
                ],
                stringArrays: ["fields"]
            )

        case .mailListMailboxes:
            return policy(strings: ["query", "role"])

        case .mailRead:
            return policy(strings: ["id"], required: ["id"])

        case .remindersSearch:
            return queryPolicy(
                integers: ["max_candidates"],
                booleans: ["incomplete_only", "completed_only"]
            )

        case .notesSearch:
            return queryPolicy(
                integers: ["max_candidates"],
                booleans: ["include_body"]
            )

        case .notesRead:
            return policy(strings: ["id"], required: ["id"])

        case .photosSearch:
            return queryPolicy(integers: ["max_candidates"])

        case .photosAlbums:
            return queryPolicy()

        case .voiceMemosSearch:
            return queryPolicy(
                integers: ["offset", "since_days", "max_candidates"],
                booleans: ["transcribed_only", "search_transcripts", "include_transcript"]
            )

        case .voiceMemosRead:
            return policy(strings: ["id"], required: ["id"])

        case .voiceMemosTranscript:
            return policy(strings: ["id", "format"], required: ["id"])

        case .voiceMemosAudio:
            return policy(
                strings: ["id", "format"],
                integers: ["max_bytes"],
                required: ["id"]
            )

        case .voiceMemosTranscribe:
            return policy(
                strings: ["id", "language"],
                integerRanges: [
                    "timeout_seconds": VoiceMemoTranscriptionTimeoutPolicy.minimumSeconds
                        ... VoiceMemoTranscriptionTimeoutPolicy.maximumSeconds
                ],
                booleans: ["prefer_stored"],
                required: ["id"]
            )

        case .aiSummarize:
            return policy(strings: ["text", "style"], required: ["text"])

        case .aiWritingTools:
            return policy(strings: ["text", "action"], required: ["text"])

        case .aiTranslate:
            return policy(
                strings: ["text", "target_language", "source_language"],
                required: ["text"]
            )

        case .aiImagePlayground:
            return policy(strings: ["concept", "style"], required: ["concept"])
        }
    }

    /// Checks unknown keys first so padding cannot push real mutation or Shortcut fields out of a
    /// bounded approval preview. Required keys and basic JSON types are then enforced before any
    /// approval handler or provider can observe the request.
    public func validationError(
        for input: [String: JSONValue],
        tool: M3MCPToolName
    ) -> M3MCPToolArgumentValidationError? {
        let unknownKeys = Set(input.keys).subtracting(allowedKeys).sorted()
        if !unknownKeys.isEmpty {
            let displayed = unknownKeys.prefix(3).map(Self.displayedKey).joined(separator: ", ")
            let remainder = unknownKeys.count - min(3, unknownKeys.count)
            let suffix = remainder > 0 ? " (+\(remainder) more)" : ""
            return M3MCPToolArgumentValidationError(
                "Invalid arguments for \(tool.rawValue): unknown key(s) \(displayed)\(suffix)."
            )
        }

        let missingKeys = requiredKeys.subtracting(input.keys).sorted()
        if !missingKeys.isEmpty {
            return M3MCPToolArgumentValidationError(
                "Invalid arguments for \(tool.rawValue): missing required key(s) "
                    + missingKeys.map(Self.displayedKey).joined(separator: ", ") + "."
            )
        }

        if !requiredAlternativeKeySets.isEmpty,
           !requiredAlternativeKeySets.contains(where: { $0.isSubset(of: input.keys) }) {
            let alternatives = requiredAlternativeKeySets
                .map { keys in keys.sorted().map(Self.displayedKey).joined(separator: " and ") }
                .joined(separator: " or ")
            return M3MCPToolArgumentValidationError(
                "Invalid arguments for \(tool.rawValue): requires \(alternatives)."
            )
        }

        for key in input.keys.sorted() {
            guard let expected = argumentTypes[key], let value = input[key] else { continue }
            if !expected.accepts(value) {
                return M3MCPToolArgumentValidationError(
                    "Invalid arguments for \(tool.rawValue): \(Self.displayedKey(key)) must be "
                        + expected.clientDescription + "."
                )
            }

            if let range = integerRanges[key], case .number(let number) = value,
               number < Double(range.lowerBound) || number > Double(range.upperBound) {
                return M3MCPToolArgumentValidationError(
                    "Invalid arguments for \(tool.rawValue): \(Self.displayedKey(key)) must be between "
                        + "\(range.lowerBound) and \(range.upperBound) inclusive."
                )
            }
        }

        return nil
    }

    private static func queryPolicy(
        strings: [String] = [],
        integers: [String] = [],
        booleans: [String] = [],
        stringArrays: [String] = []
    ) -> M3MCPToolArgumentPolicy {
        policy(
            strings: ["query"] + strings,
            integers: ["limit"] + integers,
            booleans: booleans,
            stringArrays: stringArrays
        )
    }

    private static func policy(
        strings: [String] = [],
        integers: [String] = [],
        integerRanges: [String: ClosedRange<Int>] = [:],
        booleans: [String] = [],
        stringArrays: [String] = [],
        required: Set<String> = [],
        requiredAlternatives: [Set<String>] = []
    ) -> M3MCPToolArgumentPolicy {
        var types: [String: M3MCPToolArgumentValueType] = [:]
        strings.forEach { types[$0] = .string }
        integers.forEach { types[$0] = .integer }
        integerRanges.keys.forEach { types[$0] = .integer }
        booleans.forEach { types[$0] = .boolean }
        stringArrays.forEach { types[$0] = .stringArray }
        return M3MCPToolArgumentPolicy(
            argumentTypes: types,
            integerRanges: integerRanges,
            requiredKeys: required,
            requiredAlternativeKeySets: requiredAlternatives
        )
    }

    private static func displayedKey(_ key: String) -> String {
        let escaped = key.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x20 ... 0x26, 0x28 ... 0x5B, 0x5D ... 0x7E:
                return String(scalar)
            case 0x27:
                return "\\'"
            case 0x5C:
                return "\\\\"
            default:
                return "?"
            }
        }.joined()

        var data = Data(escaped.utf8.prefix(48))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil {
            data.removeLast()
        }
        let bounded = String(data: data, encoding: .utf8) ?? "?"
        return "'\(bounded)\(escaped.utf8.count > data.count ? "..." : "")'"
    }
}
