import Foundation

/// The immutable information the app presents when a tool needs approval from the local user.
///
/// The request deliberately contains no reusable token. Approval is a one-shot Boolean decision
/// consumed by the single in-flight dispatch that created this value.
public struct M3MCPToolApprovalRequest: Equatable, Sendable {
    public let tool: M3MCPToolName
    public let argumentPreview: String

    public init(
        tool: M3MCPToolName,
        input: [String: JSONValue],
        maximumPreviewCharacters: Int = M3MCPInteractiveApproval.defaultMaximumPreviewCharacters
    ) {
        self.tool = tool
        self.argumentPreview = M3MCPInteractiveApproval.argumentPreview(
            input,
            maximumCharacters: maximumPreviewCharacters
        )
    }
}

/// Shared, deterministic approval rules used by the dispatcher and the native approval UI.
public enum M3MCPInteractiveApproval {
    public static let defaultMaximumPreviewCharacters = 1_200
    public static let maximumScalarCharacters = 240
    public static let maximumKeyCharacters = 80

    /// Calendar mutations and user-defined Shortcuts always require one local user decision per
    /// call. Permission UI is excluded because macOS supplies the authoritative prompt or settings
    /// surface itself.
    public static func requiresApproval(for tool: M3MCPToolName) -> Bool {
        switch M3MCPSecurityPolicy.classification(of: tool) {
        case .calendarMutation, .userShortcut:
            return true
        case .readOnly, .localProcessing, .localGeneration, .permissionUI:
            return false
        }
    }

    /// Produces a stable, bounded preview for a native approval dialog.
    ///
    /// Keys are sorted, nested objects remain sorted, control characters are escaped, long values
    /// are visibly truncated, and credential-like values are redacted. The preview is never a
    /// capability and must not be accepted as proof of approval.
    public static func argumentPreview(
        _ input: [String: JSONValue],
        maximumCharacters: Int = defaultMaximumPreviewCharacters
    ) -> String {
        let limit = max(0, maximumCharacters)
        guard limit > 0 else { return "" }

        if input.isEmpty {
            return bounded("(no arguments)", maximumCharacters: limit)
        }

        let keys = input.keys.sorted()
        let separatorCharacters = max(0, keys.count - 1)
        let contentCharacters = max(0, limit - separatorCharacters)
        let baseLineBudget = contentCharacters / keys.count
        let extraLineCharacters = contentCharacters % keys.count

        // Divide the fixed dialog budget across supplied top-level fields instead of truncating a
        // joined string. Approval-gated policies have a small, closed key set, so the default
        // budget always leaves room for every complete key label. Long values receive an explicit
        // per-line ellipsis and can no longer push later mutation fields out of the preview.
        return keys.enumerated().map { index, key in
            let lineBudget = baseLineBudget + (index < extraLineCharacters ? 1 : 0)
            let displayedKey = boundedEscapedString(key, maximumCharacters: maximumKeyCharacters)
            let prefix = "\(displayedKey): "
            guard lineBudget > prefix.count else {
                return bounded(prefix, maximumCharacters: lineBudget)
            }
            let value = render(input[key] ?? .null, underKey: key)
            return prefix + bounded(
                value,
                maximumCharacters: lineBudget - prefix.count
            )
        }.joined(separator: "\n")
    }

    private static let sensitiveKeyFragments: [String] = [
        "apikey",
        "authorization",
        "cookie",
        "credential",
        "passcode",
        "password",
        "privatekey",
        "secret",
        "token"
    ]

    private static func render(_ value: JSONValue, underKey key: String?) -> String {
        if let key, isSensitiveKey(key) {
            return "[REDACTED]"
        }

        switch value {
        case .string(let string):
            return "\"\(boundedEscapedString(string, maximumCharacters: maximumScalarCharacters))\""
        case .number(let number):
            return number.isFinite ? String(number) : "[NON-FINITE NUMBER]"
        case .bool(let bool):
            return bool ? "true" : "false"
        case .object(let object):
            let pairs = object.keys.sorted().map { nestedKey in
                let displayedKey = boundedEscapedString(
                    nestedKey,
                    maximumCharacters: maximumKeyCharacters
                )
                return "\"\(displayedKey)\": \(render(object[nestedKey] ?? .null, underKey: nestedKey))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        case .array(let array):
            return "[\(array.map { render($0, underKey: nil) }.joined(separator: ", "))]"
        case .null:
            return "null"
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    private static func boundedEscapedString(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        let escaped = value.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x08: return "\\b"
            case 0x09: return "\\t"
            case 0x0A: return "\\n"
            case 0x0C: return "\\f"
            case 0x0D: return "\\r"
            case 0x22: return "\\\""
            case 0x5C: return "\\\\"
            case 0x00 ... 0x1F, 0x7F:
                return String(format: "\\u{%04X}", scalar.value)
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    return String(format: "\\u{%04X}", scalar.value)
                default:
                    return String(scalar)
                }
            }
        }.joined()

        return bounded(escaped, maximumCharacters: maximumCharacters)
    }

    private static func bounded(_ value: String, maximumCharacters: Int) -> String {
        let limit = max(0, maximumCharacters)
        guard value.count > limit else { return value }
        guard limit > 1 else { return String(value.prefix(limit)) }
        return String(value.prefix(limit - 1)) + "…"
    }
}
