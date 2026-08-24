import Foundation

/// A machine-readable project marker carried inside an event's notes.
///
/// Why notes rather than a dedicated field: `EKEvent` has no user-defined properties, and the two
/// candidates that look like they would work do not survive every backend. `EKEvent.url` is dropped
/// by some CalDAV and Exchange servers, and `EKEvent.calendarItemExternalIdentifier` is assigned by
/// the store rather than the caller. `notes` is plain text that every backend round-trips, so the
/// marker is a line of text:
///
/// ```
/// Project: agent-platform-mvp
///
/// …the rest of whatever notes the caller supplied…
/// ```
///
/// The line is deliberately human-readable. Someone opening the event in Calendar.app sees which
/// project it belongs to, and a tool reading it back gets the same answer without guessing from the
/// title.
public enum CalendarProjectSlug {
    /// The key at the start of the marker line. Case-insensitive on read.
    public static let markerKey = "Project"

    /// Slugs are lowercase, start alphanumeric, and hold only `a-z 0-9 . _ -`.
    ///
    /// Validation is strict on purpose: the marker is parsed line-wise, so a slug containing a
    /// newline would let a caller inject a second marker, and a slug containing a colon would make
    /// the line ambiguous.
    public static func isValid(_ slug: String) -> Bool {
        guard (1...64).contains(slug.count) else { return false }

        var isFirst = true
        for character in slug.unicodeScalars {
            let isLowerLetter = character >= "a" && character <= "z"
            let isDigit = character >= "0" && character <= "9"
            if isFirst {
                guard isLowerLetter || isDigit else { return false }
                isFirst = false
                continue
            }
            let isSeparator = character == "-" || character == "_" || character == "."
            guard isLowerLetter || isDigit || isSeparator else { return false }
        }
        return true
    }

    /// The slug carried by `notes`, or nil when there is no marker line.
    public static func extract(from notes: String?) -> String? {
        guard let notes, !notes.isEmpty else { return nil }

        for line in lines(of: notes) {
            guard let slug = slug(inMarkerLine: line) else { continue }
            return slug
        }
        return nil
    }

    /// `notes` with the marker line for `slug` as its first line, replacing any marker already there.
    ///
    /// Returns nil when `slug` is not a valid slug, so a caller cannot write a marker it could not
    /// read back.
    public static func embed(slug: String, in notes: String?) -> String? {
        guard isValid(slug) else { return nil }

        let body = remove(from: notes) ?? ""
        let marker = "\(markerKey): \(slug)"
        guard !body.isEmpty else { return marker }
        return "\(marker)\n\n\(body)"
    }

    /// `notes` with every marker line removed, and the blank line the marker left behind.
    ///
    /// Returns nil when nothing but the marker was there, so a caller can clear `notes` entirely.
    public static func remove(from notes: String?) -> String? {
        guard let notes, !notes.isEmpty else { return nil }

        var kept: [String] = []
        for line in lines(of: notes) where slug(inMarkerLine: line) == nil {
            kept.append(line)
        }

        // Drop leading and trailing blank lines the removal exposed, but keep interior ones.
        while let first = kept.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            kept.removeFirst()
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            kept.removeLast()
        }

        let body = kept.joined(separator: "\n")
        return body.isEmpty ? nil : body
    }

    // MARK: - Internals

    /// Splits on all three line terminators. Calendar backends are not consistent about which they
    /// store, and a marker followed by `\r\n` must still parse.
    private static func lines(of text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// The slug on a marker line, or nil when the line is not a marker or carries an invalid slug.
    ///
    /// An invalid slug returns nil rather than the raw text: `extract` is used to label events, and a
    /// label nobody could have written is worse than no label.
    private static func slug(inMarkerLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(of: ":") else { return nil }

        let key = trimmed[trimmed.startIndex..<separator].trimmingCharacters(in: .whitespaces)
        guard key.lowercased() == markerKey.lowercased() else { return nil }

        let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return isValid(value) ? value : nil
    }
}
