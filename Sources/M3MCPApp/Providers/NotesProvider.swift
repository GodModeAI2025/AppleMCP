import Foundation
import M3MCPCore

final class NotesProvider {
    static let maximumQueryUTF8Bytes = 4_096
    static let maximumIdentifierUTF8Bytes = 2_048
    static let maximumScriptOutputUTF8Bytes = 2 * 1_024 * 1_024
    static let maximumReturnedIdentifierUTF8Bytes = 2_048
    static let maximumReturnedTitleUTF8Bytes = 1_024
    static let maximumReturnedFolderUTF8Bytes = 512
    static let maximumReturnedModifiedUTF8Bytes = 128
    private static let metadataRowMarker = "__M3MCP_NOTES_META_V1__"

    private struct ParsedOutput {
        let items: [DataItem]
        let inspected: Int?
        let available: Int?
        let budgetCapped: Bool
        let outputLimitCapped: Bool
        let searchContentCapped: Bool
    }

    typealias PermissionPreflight = @Sendable () async -> AutomationPermission.Status
    typealias ScriptExecution = @Sendable (String) async -> Result<String, AppleScriptRunner.Failure>

    private let permissionPreflight: PermissionPreflight
    private let scriptExecution: ScriptExecution

    init(
        permissionPreflight: @escaping PermissionPreflight = {
            await AutomationPermission.notesForToolExecution()
        },
        scriptExecution: @escaping ScriptExecution = { source in
            await AppleScriptRunner.run(source)
        }
    ) {
        self.permissionPreflight = permissionPreflight
        self.scriptExecution = scriptExecution
    }

    func search(input: [String: JSONValue]) async -> ToolResponse {
        guard !Task.isCancelled else { return cancellationResponse() }

        let rawQuery = input.string("query")
        guard rawQuery.utf8.count <= Self.maximumQueryUTF8Bytes else {
            return ToolResponse(
                ok: false,
                source: "Notes.app",
                message: "Notes query exceeds the \(Self.maximumQueryUTF8Bytes)-byte work limit."
            )
        }
        let limit = max(1, min(input.int("limit", default: 25), 100))
        let includeBody = input.bool("include_body", default: !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let maxCandidates = max(limit, min(input.int("max_candidates", default: 500), 2_000))
        let query = StringSanitizer.lower(rawQuery)

        guard !Task.isCancelled else { return cancellationResponse() }
        let permission = await permissionPreflight()
        guard !Task.isCancelled, permission.state != "cancelled" else {
            return cancellationResponse()
        }
        guard permission.isAuthorized else {
            return ToolResponse(
                ok: false,
                source: "Notes.app",
                message: permission.message ?? "Notes.app Automation permission is not authorized."
            )
        }

        let script = buildSearchScript(query: query, limit: limit, includeBody: includeBody, maxCandidates: maxCandidates)
        guard !Task.isCancelled else { return cancellationResponse() }
        let result = await scriptExecution(script)
        guard !Task.isCancelled else { return cancellationResponse() }

        switch result {
        case .success(let output):
            guard output.utf8.count <= Self.maximumScriptOutputUTF8Bytes else {
                return ToolResponse(
                    ok: false,
                    source: "Notes.app",
                    message: "Notes returned more than the \(Self.maximumScriptOutputUTF8Bytes)-byte response work limit. Narrow the query."
                )
            }
            let parsed = parseRows(output, previewMaximumUTF8Bytes: 4_800)
            let message: String?
            if parsed.budgetCapped {
                message = "Notes search reached its \(maxCandidates)-note inspection budget; narrow the query or raise max_candidates."
            } else if parsed.outputLimitCapped {
                message = "Notes stopped after returning limit matches; additional notes were not inspected."
            } else if parsed.searchContentCapped {
                message = "Some note fields exceeded the per-field search budget; matches beyond those prefixes were not inspected."
            } else {
                message = parsed.items.isEmpty ? "No matching notes found." : nil
            }
            return ToolResponse(
                ok: true,
                source: "Notes.app",
                items: parsed.items,
                message: message,
                meta: responseMeta(for: parsed, scanBudget: maxCandidates)
            )
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
        guard !Task.isCancelled else { return cancellationResponse() }

        // Reject malformed direct provider calls before permission preflight can launch Notes.
        // LocalMCPService validates this too, but the provider remains a side-effect boundary.
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: "Notes.app", message: "Missing required argument: id")
        }
        guard id.utf8.count <= Self.maximumIdentifierUTF8Bytes else {
            return ToolResponse(
                ok: false,
                source: "Notes.app",
                message: "Notes id exceeds the \(Self.maximumIdentifierUTF8Bytes)-byte input limit."
            )
        }

        guard !Task.isCancelled else { return cancellationResponse() }
        let permission = await permissionPreflight()
        guard !Task.isCancelled, permission.state != "cancelled" else {
            return cancellationResponse()
        }
        guard permission.isAuthorized else {
            return ToolResponse(
                ok: false,
                source: "Notes.app",
                message: permission.message ?? "Notes.app Automation permission is not authorized."
            )
        }

        let script = buildReadScript(id: id)
        guard !Task.isCancelled else { return cancellationResponse() }
        let result = await scriptExecution(script)
        guard !Task.isCancelled else { return cancellationResponse() }
        switch result {
        case .success(let output):
            guard output.utf8.count <= Self.maximumScriptOutputUTF8Bytes else {
                return ToolResponse(
                    ok: false,
                    source: "Notes.app",
                    message: "Notes returned more than the \(Self.maximumScriptOutputUTF8Bytes)-byte response work limit."
                )
            }
            let parsed = parseRows(output, previewMaximumUTF8Bytes: 262_144)
            let boundedLookup = parsed.items.isEmpty && parsed.budgetCapped
            return ToolResponse(
                ok: !parsed.items.isEmpty,
                source: "Notes.app",
                items: parsed.items,
                message: parsed.items.isEmpty
                    ? (boundedLookup
                        ? "Note was not found in the bounded 5000-note lookup."
                        : "Note not found.")
                    : nil,
                meta: responseMeta(for: parsed, scanBudget: 5_000)
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

    private func cancellationResponse() -> ToolResponse {
        ToolResponse(ok: false, source: "Notes.app", message: "Notes request was cancelled.")
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
        set _rows to ""
        set _matched to 0
        set _inspected to 0
        set _searchContentCapped to false
        tell application "Notes"
            set _availableCount to count of notes
            set _count to _availableCount
            if _count > _maxCandidates then set _count to _maxCandidates
            repeat with _i from 1 to _count
                if _matched >= _limit then exit repeat
                set _inspected to _inspected + 1
                set _n to note _i
                set _truncated to false
                set _nameRaw to my cleanText(name of _n)
                set _name to my truncateText(_nameRaw, 512)
                if length of _nameRaw > 512 then
                    set _truncated to true
                    set _searchContentCapped to true
                end if
                try
                    set _folderRaw to my cleanText(name of container of _n)
                    set _folder to my truncateText(_folderRaw, 512)
                    if length of _folderRaw > 512 then set _truncated to true
                on error
                    set _folder to "(unknown)"
                end try
                set _modifiedRaw to my cleanText(modification date of _n as text)
                set _modified to my truncateText(_modifiedRaw, 128)
                if length of _modifiedRaw > 128 then set _truncated to true
                set _body to ""
                if _includeBody then
                    set _bodyRaw to my cleanText(plaintext of _n)
                    set _body to my truncateText(_bodyRaw, 1200)
                    if length of _bodyRaw > 1200 then
                        set _truncated to true
                        set _searchContentCapped to true
                    end if
                end if
                set _matches to true
                if _query is not "" then
                    set _haystack to _name & " " & _body
                    ignoring case
                        if _haystack does not contain _query then set _matches to false
                    end ignoring
                end if
                if _matches then
                    set _idRaw to my cleanText(id of _n as text)
                    set _id to my truncateText(_idRaw, 2048)
                    if length of _idRaw > 2048 then set _truncated to true
                    set _rows to _rows & _id & tab & _name & tab & _folder & tab & _modified & tab & _body & tab & (_truncated as text) & linefeed
                    set _matched to _matched + 1
                end if
            end repeat
        end tell
        set _budgetCapped to (_inspected >= _maxCandidates and _inspected < _availableCount)
        set _outputLimitCapped to (_matched >= _limit and _inspected < _availableCount)
        set _meta to "__M3MCP_NOTES_META_V1__" & tab & (_inspected as text) & tab & (_availableCount as text) & tab & (_budgetCapped as text) & tab & (_outputLimitCapped as text) & tab & (_searchContentCapped as text) & linefeed
        return _meta & _rows

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

        on truncateText(_value, _limit)
            if length of _value > _limit then return text 1 thru _limit of _value
            return _value
        end truncateText
        """
    }

    private func buildReadScript(id: String) -> String {
        let escapedID = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        set _idToFind to "\(escapedID)"
        set _rows to ""
        set _maxCandidates to 5000
        set _inspected to 0
        tell application "Notes"
            set _availableCount to count of notes
            set _count to _availableCount
            if _count > _maxCandidates then set _count to _maxCandidates
            repeat with _i from 1 to _count
                set _inspected to _inspected + 1
                set _n to note _i
                set _idRaw to my cleanText(id of _n as text)
                if _idRaw is _idToFind then
                    set _truncated to false
                    set _id to my truncateText(_idRaw, 2048)
                    if length of _idRaw > 2048 then set _truncated to true
                    set _nameRaw to my cleanText(name of _n)
                    set _name to my truncateText(_nameRaw, 512)
                    if length of _nameRaw > 512 then set _truncated to true
                    try
                        set _folderRaw to my cleanText(name of container of _n)
                        set _folder to my truncateText(_folderRaw, 512)
                        if length of _folderRaw > 512 then set _truncated to true
                    on error
                        set _folder to "(unknown)"
                    end try
                    set _modifiedRaw to my cleanText(modification date of _n as text)
                    set _modified to my truncateText(_modifiedRaw, 128)
                    if length of _modifiedRaw > 128 then set _truncated to true
                    set _bodyRaw to my cleanText(plaintext of _n)
                    set _body to my truncateText(_bodyRaw, 65536)
                    if length of _bodyRaw > 65536 then
                        set _truncated to true
                    end if
                    set _rows to _id & tab & _name & tab & _folder & tab & _modified & tab & _body & tab & (_truncated as text) & linefeed
                    exit repeat
                end if
            end repeat
        end tell
        set _budgetCapped to (_rows is "" and _inspected >= _maxCandidates and _inspected < _availableCount)
        set _meta to "__M3MCP_NOTES_META_V1__" & tab & (_inspected as text) & tab & (_availableCount as text) & tab & (_budgetCapped as text) & tab & "false" & tab & "false" & linefeed
        return _meta & _rows

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

        on truncateText(_value, _limit)
            if length of _value > _limit then return text 1 thru _limit of _value
            return _value
        end truncateText
        """
    }

    private func parseRows(_ output: String, previewMaximumUTF8Bytes: Int) -> ParsedOutput {
        var items: [DataItem] = []
        var inspected: Int?
        var available: Int?
        var budgetCapped = false
        var outputLimitCapped = false
        var searchContentCapped = false

        for row in output.split(separator: "\n") {
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if columns.first == Self.metadataRowMarker, columns.count >= 6 {
                inspected = Int(columns[1])
                available = Int(columns[2])
                budgetCapped = columns[3].localizedLowercase == "true"
                outputLimitCapped = columns[4].localizedLowercase == "true"
                searchContentCapped = columns[5].localizedLowercase == "true"
                continue
            }
            guard columns.count >= 5 else { continue }
                let identifier = ProviderOutputBudget.text(
                    columns[0],
                    maximumUTF8Bytes: Self.maximumReturnedIdentifierUTF8Bytes
                )
                let title = ProviderOutputBudget.text(
                    columns[1],
                    maximumUTF8Bytes: Self.maximumReturnedTitleUTF8Bytes
                )
                let folder = ProviderOutputBudget.text(
                    columns[2],
                    maximumUTF8Bytes: Self.maximumReturnedFolderUTF8Bytes
                )
                let modified = ProviderOutputBudget.text(
                    columns[3],
                    maximumUTF8Bytes: Self.maximumReturnedModifiedUTF8Bytes
                )
                let preview = ProviderOutputBudget.text(
                    columns[4],
                    maximumUTF8Bytes: previewMaximumUTF8Bytes
                )
                let scriptTruncated = columns.count >= 6 && columns[5] == "true"
                let contentTruncated = scriptTruncated || preview.truncated
                    || identifier.truncated || title.truncated || folder.truncated || modified.truncated
                items.append(DataItem(
                    id: identifier.text.isEmpty ? UUID().uuidString : identifier.text,
                    title: title.text.isEmpty ? "(untitled note)" : title.text,
                    subtitle: folder.text.isEmpty ? nil : folder.text,
                    kind: "note",
                    source: "Notes.app",
                    preview: preview.text,
                    metadata: [
                        "folder": folder.text,
                        "modified": modified.text,
                        "content_truncated": String(contentTruncated)
                    ]
                ))
        }

        return ParsedOutput(
            items: items,
            inspected: inspected,
            available: available,
            budgetCapped: budgetCapped,
            outputLimitCapped: outputLimitCapped,
            searchContentCapped: searchContentCapped
        )
    }

    private func responseMeta(for parsed: ParsedOutput, scanBudget: Int) -> [String: String] {
        let scanCapped = parsed.budgetCapped || parsed.outputLimitCapped
        let fieldsTruncated = parsed.items.contains {
            $0.metadata["content_truncated"] == "true"
        }
        var meta: [String: String] = [
            "returned": String(parsed.items.count),
            "scan_budget": String(scanBudget),
            "scan_capped": String(scanCapped),
            "budget_capped": String(parsed.budgetCapped),
            "output_limit_capped": String(parsed.outputLimitCapped),
            "search_content_capped": String(parsed.searchContentCapped),
            "matching_total_exact": String(!scanCapped && !parsed.searchContentCapped),
            "has_more": String(scanCapped),
            "truncated": String(scanCapped || parsed.searchContentCapped || fieldsTruncated)
        ]
        if let inspected = parsed.inspected {
            meta["inspected"] = String(inspected)
        }
        if let available = parsed.available {
            meta["candidates_available"] = String(available)
        }
        return meta
    }
}
