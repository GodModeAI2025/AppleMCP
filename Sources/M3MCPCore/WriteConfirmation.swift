import CryptoKit
import Foundation

/// Turns a calendar write into two steps: ask, then confirm.
///
/// The first call to a write tool changes nothing. It comes back `ok: false` with a preview of what
/// would happen and a `confirm_token` in `meta`. The second call repeats the same arguments plus that
/// token and goes through. A model that decided to delete a calendar on its own therefore has to
/// state the intention twice, with the preview in between, and the preview is what a person reads.
///
/// The token is an HMAC over the tool name and the arguments, not a nonce in a table. Three
/// properties come out of that, and all three matter:
///
///  * it is bound to the exact call. A token issued for moving one meeting cannot confirm deleting a
///    calendar, because the arguments are inside the MAC.
///  * it expires. Five minutes, carried in the token and covered by the MAC, so a token that sat in a
///    transcript is not still good tomorrow.
///  * it needs no state. The key is random per app start, which also means every pending confirmation
///    is void after a restart — the right default for something whose whole purpose is that the user
///    still remembers agreeing to it.
public struct WriteConfirmation: Sendable {
    /// Long enough for a person to read a preview and answer, short enough that a token in a chat
    /// log is not a standing permission.
    public static let validity: TimeInterval = 300

    public static let argumentName = "confirm_token"

    private let key: SymmetricKey
    private let validity: TimeInterval

    /// A fresh key per instance: the app makes one at start-up, so confirmations do not survive a
    /// restart, and a test makes its own.
    public init(validity: TimeInterval = WriteConfirmation.validity) {
        self.key = SymmetricKey(size: .bits256)
        self.validity = validity
    }

    public func issue(tool: String, input: [String: JSONValue], now: Date = Date()) -> (token: String, expiresAt: Date) {
        let expiry = now.addingTimeInterval(validity)
        let seconds = Int(expiry.timeIntervalSince1970)
        return ("\(seconds).\(signature(tool: tool, input: input, expiry: seconds))", Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    public enum Verdict: Sendable, Equatable {
        case valid
        case missing
        case malformed
        case expired
        case mismatched
    }

    public func verify(token: String?, tool: String, input: [String: JSONValue], now: Date = Date()) -> Verdict {
        guard let token, !token.isEmpty else { return .missing }

        let parts = token.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let expiry = Int(parts[0]) else { return .malformed }

        // Expiry is checked before the MAC only to give a clearer message; the MAC covers the expiry
        // too, so a client cannot move it.
        guard TimeInterval(expiry) >= now.timeIntervalSince1970 else { return .expired }

        let expected = signature(tool: tool, input: input, expiry: expiry)
        return CapabilityToken.matches(String(parts[1]), expected) ? .valid : .mismatched
    }

    private func signature(tool: String, input: [String: JSONValue], expiry: Int) -> String {
        var arguments = input
        arguments.removeValue(forKey: Self.argumentName)

        let message = "\(tool)\n\(expiry)\n\(JSONValue.object(arguments).canonicalText)"
        var mac = HMAC<SHA256>(key: key)
        mac.update(data: Data(message.utf8))
        return Data(mac.finalize())
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public extension JSONValue {
    /// A deterministic text form, so the same arguments always produce the same MAC.
    ///
    /// Keys sorted, no whitespace, integral numbers written without a decimal point. `JSONEncoder`
    /// with `.sortedKeys` would nearly do, but it can throw and it puts `1` and `1.0` in different
    /// places depending on how the value was decoded.
    var canonicalText: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            return Self.quote(value)
        case .array(let values):
            return "[" + values.map { $0.canonicalText }.joined(separator: ",") + "]"
        case .object(let values):
            let pairs = values.keys.sorted().map { key in
                Self.quote(key) + ":" + (values[key] ?? .null).canonicalText
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}
