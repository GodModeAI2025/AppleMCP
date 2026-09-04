import Foundation

/// Shared validation for identifiers that cross from an MCP request into filesystem or database
/// lookups. Keeping these invariants explicit avoids relying on SQLite's implicit type coercion.
public enum M3InputValidation {
    /// Accepts the canonical decimal spelling of a positive unsigned integer.
    ///
    /// Values with whitespace, signs, decimal points, leading zeroes, path separators, or values
    /// outside `UInt64` are rejected.
    public static func isCanonicalPositiveDecimal(_ raw: String) -> Bool {
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ (48...57).contains($0) }),
              raw.first != "0",
              let value = UInt64(raw),
              value > 0 else {
            return false
        }
        return String(value) == raw
    }

    /// Accepts a SHA-256 digest encoded as exactly 64 ASCII hexadecimal characters.
    ///
    /// Voice Memos normally stores this value as a 32-byte blob, but some schema variants expose
    /// text. Validating the textual fallback keeps a database value from becoming a cache path.
    public static func isSHA256HexDigest(_ raw: String) -> Bool {
        guard raw.utf8.count == 64 else { return false }
        return raw.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    /// Returns a valid-Unicode prefix whose UTF-8 representation fits the byte budget. This is
    /// suitable for bounding JSON-bound text because it never cuts through a multi-byte scalar.
    public static func boundedUTF8Prefix(
        _ raw: String,
        maximumBytes: Int
    ) -> (text: String, truncated: Bool) {
        let boundedMaximum = max(0, maximumBytes)
        guard raw.utf8.count > boundedMaximum else {
            return (raw, false)
        }

        var prefix = Data(raw.utf8.prefix(boundedMaximum))
        while !prefix.isEmpty {
            if let text = String(data: prefix, encoding: .utf8) {
                return (text, true)
            }
            // UTF-8 scalars are at most four bytes, so this loop removes at most three bytes.
            prefix.removeLast()
        }
        return ("", true)
    }
}
