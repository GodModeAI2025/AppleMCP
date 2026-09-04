import Foundation
import M3MCPCore

/// Small, provider-facing helpers for bounding untrusted Apple-store strings before they enter a
/// `ToolResponse`. Character counts do not bound JSON because one control byte can become six bytes
/// after escaping, so every provider limit passed here is expressed in UTF-8 bytes.
struct ProviderBoundedText: Equatable, Sendable {
    let text: String
    let originalBytes: Int
    let truncated: Bool
}

enum ProviderOutputBudget {
    static func text(_ value: String, maximumUTF8Bytes: Int) -> ProviderBoundedText {
        let bounded = M3InputValidation.boundedUTF8Prefix(value, maximumBytes: maximumUTF8Bytes)
        return ProviderBoundedText(
            text: bounded.text,
            originalBytes: value.utf8.count,
            truncated: bounded.truncated
        )
    }

    static func joined(
        _ values: [String],
        maximumEntries: Int,
        maximumEntryUTF8Bytes: Int,
        separator: String
    ) -> ProviderBoundedText {
        let entryLimit = max(0, maximumEntries)
        let retained = values.prefix(entryLimit).map {
            text($0, maximumUTF8Bytes: maximumEntryUTF8Bytes)
        }
        let joined = retained.map(\.text).joined(separator: separator)
        return ProviderBoundedText(
            text: joined,
            originalBytes: values.reduce(into: 0) { total, value in
                let addition = total.addingReportingOverflow(value.utf8.count)
                total = addition.overflow ? Int.max : addition.partialValue
            },
            truncated: values.count > retained.count || retained.contains(where: \.truncated)
        )
    }
}
