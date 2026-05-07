import Foundation

enum StringSanitizer {
    static func compact(_ value: String, limit: Int = 1_200) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        if normalized.count <= limit {
            return normalized
        }

        return String(normalized.prefix(limit))
    }

    static func lower(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }
}
