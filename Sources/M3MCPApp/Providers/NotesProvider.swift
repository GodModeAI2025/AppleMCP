import Foundation
import M3MCPCore

final class NotesProvider {
    func search(input: [String: JSONValue]) async -> ToolResponse {
        let permission = await AutomationPermission.notes(prompt: false)
        guard permission.isAuthorized else {
            return ToolResponse(
                ok: false,
                source: "Notes.app",
                message: permission.message ?? "Notes.app Automation permission is not authorized."
            )
        }

        let rawQuery = input.string("query")
        let limit = max(1, min(input.int("limit", default: 25), 100))
        let includeBody = input.bool("include_body", default: !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let maxCandidates = max(limit, min(input.int("max_candidates", default: 500), 2_000))
        let query = StringSanitizer.lower(rawQuery)

        let script = buildSearchScript(query: query, limit: limit, includeBody: includeBody, maxCandidates: maxCandidates)
        let result = await AppleScriptRunner.run(script)

        switch result {
        case .success(let output):
            let items = parseRows(output)
            let message = items.isEmpty ? "No matching notes found." : nil
            return ToolResponse(ok: true, source: "Notes.app", items: items, message: message)
        case .failure(let error):
            let detail = StringSanitizer.compact(error.message, limit: 800)
            return ToolResponse(
                ok: false,
                source: "Notes.app",
                message: "Notes.app Automation permission is missing or Notes is unavailable. \(detail)"
            )
        }
    }

    func read(input: [String: JSONValue]) async -> ToolResponse {
        let permission = await AutomationPermission.notes(prompt: false)
        guard permission.isAuthorized else {
            return ToolResponse(
                ok: false,
                source: "Notes.app",
                message: permission.message ?? "Notes.app Automation permission is not authorized."
            )
        }

        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: "Notes.app", message: "Missing required argument: id")
        }

        let script = buildReadScript(id: id)
        let result = await AppleScriptRunner.run(script)
        switch result {
        case .success(let output):
            let items = parseRows(output)
            return ToolResponse(
                ok: !items.isEmpty,
                source: "Notes.app",
                items: items,
                message: items.isEmpty ? "Note not found." : nil
            )
        case .failure(let error):
            let detail = StringSanitizer.compact(error.message, limit: 800)
            return ToolResponse(
                ok: false,
                source: "Notes.app",
                message: "Notes.app is authorized, but did not answer its Apple Event interface. \(detail)"
            )
        }
    }

    private func buildSearchScript(query: String, limit: Int, includeBody: Bool, maxCandidates: Int) -> String {
        let escapedQuery = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let includeBodyAS = includeBody ? "true" : "false"

        return """
        set _limit to \(limit)
        set _query to "\(escapedQuery)"
        set _includeBody to \(includeBodyAS)
        set _maxCandidates to \(maxCandidates)
        set _out to ""
        set _matched to 0
        tell application "Notes"
            set _allNotes to every note
            set _count to count of _allNotes
            if _count > _maxCandidates then set _count to _maxCandidates
            repeat with _i from 1 to _count
                if _matched >= _limit then exit repeat
                set _n to item _i of _allNotes
                set _name to my cleanText(name of _n)
                try
                    set _folder to my cleanText(name of container of _n)
                on error
                    set _folder to "(unknown)"
                end try
                set _modified to my cleanText(modification date of _n as text)
                set _body to ""
                if _includeBody then
                    set _body to my cleanText(plaintext of _n)
                    if length of _body > 1200 then set _body to text 1 thru 1200 of _body
                end if
                set _matches to true
                if _query is not "" then
                    set _haystack to _name & " " & _body
                    ignoring case
                        if _haystack does not contain _query then set _matches to false
                    end ignoring
                end if
                if _matches then
                    set _id to my cleanText(id of _n as text)
                    set _out to _out & _id & tab & _name & tab & _folder & tab & _modified & tab & _body & linefeed
                    set _matched to _matched + 1
                end if
            end repeat
        end tell
        return _out

        on cleanText(_value)
            try
                set _text to _value as text
                set AppleScript's text item delimiters to linefeed
                set _parts to text items of _text
                set AppleScript's text item delimiters to " "
                set _text to _parts as text
                set AppleScript's text item delimiters to tab
                set _parts to text items of _text
                set AppleScript's text item delimiters to " "
                set _text to _parts as text
                set AppleScript's text item delimiters to ""
                return _text
            on error
                return ""
            end try
        end cleanText
        """
    }

    private func buildReadScript(id: String) -> String {
        let escapedID = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        set _idToFind to "\(escapedID)"
        set _out to ""
        tell application "Notes"
            repeat with _n in every note
                set _id to my cleanText(id of _n as text)
                if _id is _idToFind then
                    set _name to my cleanText(name of _n)
                    try
                        set _folder to my cleanText(name of container of _n)
                    on error
                        set _folder to "(unknown)"
                    end try
                    set _modified to my cleanText(modification date of _n as text)
                    set _body to my cleanText(plaintext of _n)
                    set _out to _id & tab & _name & tab & _folder & tab & _modified & tab & _body & linefeed
                    exit repeat
                end if
            end repeat
        end tell
        return _out

        on cleanText(_value)
            try
                set _text to _value as text
                set AppleScript's text item delimiters to linefeed
                set _parts to text items of _text
                set AppleScript's text item delimiters to " "
                set _text to _parts as text
                set AppleScript's text item delimiters to tab
                set _parts to text items of _text
                set AppleScript's text item delimiters to " "
                set _text to _parts as text
                set AppleScript's text item delimiters to ""
                return _text
            on error
                return ""
            end try
        end cleanText
        """
    }

    private func parseRows(_ output: String) -> [DataItem] {
        output
            .split(separator: "\n")
            .compactMap { row in
                let columns = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard columns.count >= 5 else { return nil }
                return DataItem(
                    id: columns[0].isEmpty ? UUID().uuidString : columns[0],
                    title: columns[1].isEmpty ? "(untitled note)" : columns[1],
                    subtitle: columns[2].isEmpty ? nil : columns[2],
                    kind: "note",
                    source: "Notes.app",
                    preview: StringSanitizer.compact(columns[4], limit: 1_000),
                    metadata: [
                        "folder": columns[2],
                        "modified": columns[3]
                    ]
                )
            }
    }
}
