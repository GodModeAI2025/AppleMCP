import Foundation
import M3MCPCore
import SQLite3

/// Read-only access to the local Voice Memos library.
///
/// Voice Memos keeps its metadata in a Core Data SQLite store (`CloudRecordings.db`) next to the
/// `.m4a` recordings. Transcripts live inside the recordings themselves, so this provider reads the
/// store directly instead of driving Voice Memos.app through AppleEvents.
final class VoiceMemosProvider {
    private let fileManager = FileManager.default
    private let sourceName = "Voice Memos"

    private let libraryPaths = [
        "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings",
        "Library/Application Support/com.apple.voicememos/Recordings",
        "Library/Containers/com.apple.VoiceMemos/Data/Library/Application Support/Recordings"
    ]
    private let databaseName = "CloudRecordings.db"

    // MARK: - Tools

    func search(input: [String: JSONValue]) async -> ToolResponse {
        let query = StringSanitizer.lower(input.string("query"))
        let limit = max(1, min(input.int("limit", default: 25), 100))
        let offset = max(0, input.int("offset", default: 0))
        let sinceDays = max(0, input.int("since_days", default: 0))
        let transcribedOnly = input.bool("transcribed_only", default: false)
        let searchTranscripts = input.bool("search_transcripts", default: false)
        let includeTranscript = input.bool("include_transcript", default: false)
        let maxCandidates = max(limit, min(input.int("max_candidates", default: 300), 2_000))

        do {
            let store = try locateStore()
            let needsFileFilter = transcribedOnly || (searchTranscripts && !query.isEmpty)
            let fetchLimit = needsFileFilter ? maxCandidates : limit
            let fetchOffset = needsFileFilter ? 0 : offset

            let page = try withDatabase(at: store.database) { database -> RecordingPage in
                try readRecordings(
                    database: database,
                    store: store,
                    titleQuery: searchTranscripts ? "" : query,
                    sinceDays: sinceDays,
                    limit: fetchLimit,
                    offset: fetchOffset
                )
            }

            let readsTranscripts = needsFileFilter || includeTranscript
            var matches: [(row: RecordingRow, transcript: VoiceMemoTranscript?, hasTranscript: Bool)] = []

            for row in page.rows {
                let transcript = readsTranscripts ? row.transcript() : nil
                let hasTranscript = readsTranscripts ? (transcript != nil) : row.hasTranscript()

                if transcribedOnly, !hasTranscript {
                    continue
                }

                if searchTranscripts, !query.isEmpty {
                    let haystack = StringSanitizer.lower("\(row.title) \(transcript?.text ?? "")")
                    guard haystack.contains(query) else { continue }
                }

                matches.append((row: row, transcript: transcript, hasTranscript: hasTranscript))
            }

            let total = needsFileFilter ? matches.count : page.total
            let window = needsFileFilter ? Array(matches.dropFirst(offset).prefix(limit)) : matches

            let items = window.map { match in
                makeItem(
                    match.row,
                    transcript: includeTranscript ? match.transcript : nil,
                    hasTranscript: match.hasTranscript
                )
            }

            var message: String?
            if items.isEmpty {
                message = "No matching voice memos found."
            } else if total > items.count + offset {
                message = "Showing \(items.count) of \(total) matching voice memos. Use offset to page through the rest."
            } else if needsFileFilter, page.rows.count >= maxCandidates {
                message = "Inspected the \(maxCandidates) most recent recordings. Raise max_candidates to search further back."
            }

            return ToolResponse(ok: true, source: sourceName, items: items, message: message)
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    func read(input: [String: JSONValue]) async -> ToolResponse {
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: sourceName, message: "Missing required argument: id")
        }

        do {
            let row = try loadRecording(id: id)
            let transcript = row.transcript()
            return ToolResponse(ok: true, source: sourceName, items: [makeDetailItem(row, transcript: transcript)])
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    func transcript(input: [String: JSONValue]) async -> ToolResponse {
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: sourceName, message: "Missing required argument: id")
        }

        let format = input.string("format", default: "text")
        let validFormats = ["text", "timestamped", "json"]
        guard validFormats.contains(format) else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Invalid format '\(format)'. Valid values: \(validFormats.joined(separator: ", "))"
            )
        }

        do {
            let row = try loadRecording(id: id)
            guard let transcript = row.transcript() else {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "This recording carries no stored transcript. Open it in Voice Memos on macOS Sequoia or later to let macOS transcribe it, or call voicememos_transcribe."
                )
            }

            var metadata = baseMetadata(row)
            metadata["locale"] = transcript.locale
            metadata["segment_count"] = String(transcript.segments.count)
            metadata["format"] = format
            metadata["origin"] = "stored"

            let preview: String
            switch format {
            case "timestamped":
                preview = VoiceMemoTranscriptReader.timestampedText(transcript)
            case "json":
                preview = transcript.text
                if let encoded = encodeSegments(transcript.segments) {
                    metadata["segments_json"] = encoded
                }
            default:
                preview = transcript.text
            }

            let item = DataItem(
                id: row.id,
                title: row.title,
                subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
                kind: "voice_memo_transcript",
                source: sourceName,
                preview: preview,
                metadata: metadata
            )

            return ToolResponse(ok: true, source: sourceName, items: [item])
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    func audio(input: [String: JSONValue]) async -> ToolResponse {
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: sourceName, message: "Missing required argument: id")
        }

        let format = input.string("format", default: "path")
        let validFormats = ["path", "base64"]
        guard validFormats.contains(format) else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Invalid format '\(format)'. Valid values: \(validFormats.joined(separator: ", "))"
            )
        }

        let maxBytes = max(1, min(input.int("max_bytes", default: 8_000_000), 25_000_000))

        do {
            let row = try loadRecording(id: id)
            guard let fileURL = row.fileURL else {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "The recording file for '\(row.title)' is not on this Mac. It may still live in iCloud only."
                )
            }

            var metadata = baseMetadata(row)
            metadata["mime_type"] = mimeType(for: fileURL)
            metadata["format"] = format

            let size = fileSize(of: fileURL)
            if let size {
                metadata["bytes"] = String(size)
            }

            if format == "path" {
                let item = DataItem(
                    id: row.id,
                    title: row.title,
                    subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
                    kind: "voice_memo_audio",
                    source: sourceName,
                    preview: fileURL.path,
                    metadata: metadata
                )
                return ToolResponse(ok: true, source: sourceName, items: [item])
            }

            if let size, size > maxBytes {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "The recording is \(size) bytes and exceeds max_bytes (\(maxBytes)). Use format 'path', or raise max_bytes."
                )
            }

            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "Cannot read \(fileURL.path). Grant Full Disk Access to M3MCP, then restart the app."
                )
            }

            guard data.count <= maxBytes else {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "The recording is \(data.count) bytes and exceeds max_bytes (\(maxBytes)). Use format 'path', or raise max_bytes."
                )
            }

            metadata["bytes"] = String(data.count)
            metadata["encoding"] = "base64"

            let item = DataItem(
                id: row.id,
                title: row.title,
                subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
                kind: "voice_memo_audio",
                source: sourceName,
                preview: data.base64EncodedString(),
                metadata: metadata
            )
            return ToolResponse(ok: true, source: sourceName, items: [item])
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    func transcribe(input: [String: JSONValue]) async -> ToolResponse {
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: sourceName, message: "Missing required argument: id")
        }

        let requestedLanguage = input.string("language").trimmingCharacters(in: .whitespacesAndNewlines)
        let language = requestedLanguage.isEmpty ? Locale.current.identifier : requestedLanguage
        let timeout = TimeInterval(max(10, min(input.int("timeout_seconds", default: Int(SpeechTranscriber.defaultTimeout)), 1_800)))
        let preferStored = input.bool("prefer_stored", default: true)

        do {
            let row = try loadRecording(id: id)

            if preferStored, let stored = row.transcript() {
                var metadata = baseMetadata(row)
                metadata["locale"] = stored.locale
                metadata["segment_count"] = String(stored.segments.count)
                metadata["origin"] = "stored"

                let item = DataItem(
                    id: row.id,
                    title: row.title,
                    subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
                    kind: "voice_memo_transcript",
                    source: sourceName,
                    preview: stored.text,
                    metadata: metadata
                )
                return ToolResponse(
                    ok: true,
                    source: sourceName,
                    items: [item],
                    message: "Returned the transcript macOS already stored in the recording. Set prefer_stored to false to re-run speech recognition."
                )
            }

            guard let fileURL = row.fileURL else {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "The recording file for '\(row.title)' is not on this Mac. It may still live in iCloud only."
                )
            }

            let result = try await SpeechTranscriber.transcribe(url: fileURL, languageCode: language, timeout: timeout)

            var metadata = baseMetadata(row)
            metadata["locale"] = result.locale
            metadata["segment_count"] = String(result.segments.count)
            metadata["on_device"] = String(result.onDevice)
            metadata["origin"] = "speech_recognition"
            if let encoded = encodeSegments(result.segments) {
                metadata["segments_json"] = encoded
            }

            let item = DataItem(
                id: row.id,
                title: row.title,
                subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
                kind: "voice_memo_transcript",
                source: sourceName,
                preview: result.text,
                metadata: metadata
            )
            return ToolResponse(ok: true, source: sourceName, items: [item])
        } catch let failure as SpeechTranscriber.Failure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    /// Reports whether the local Voice Memos store is readable, mirroring the Mail index preflight.
    func accessStatus() -> (state: String, message: String?) {
        do {
            let store = try locateStore()
            try withDatabase(at: store.database) { database in
                let columns = try tableColumns(database: database, table: "ZCLOUDRECORDING")
                guard !columns.isEmpty else {
                    throw VoiceMemoStoreFailure("The Voice Memos store is readable, but the ZCLOUDRECORDING table was not found.")
                }
            }
            return ("authorized", "Local Voice Memos store is readable.")
        } catch let failure as VoiceMemoStoreFailure {
            return ("manual", failure.message)
        } catch {
            return ("manual", error.localizedDescription)
        }
    }

    // MARK: - Model

    private struct RecordingStore {
        let recordings: URL
        let database: URL
    }

    private struct RecordingRow {
        let id: String
        let title: String
        let customLabel: String?
        let date: Date?
        let duration: Double
        let filename: String
        let fileURL: URL?
        let deletedAt: Date?

        var subtitle: String {
            var parts: [String] = []
            if let date {
                parts.append(RecordingRow.displayFormatter.string(from: date))
            }
            if duration > 0 {
                parts.append(VoiceMemoTranscriptReader.timecode(duration))
            }
            return parts.joined(separator: " · ")
        }

        func transcript() -> VoiceMemoTranscript? {
            guard let fileURL else { return nil }
            return VoiceMemoTranscriptReader.read(at: fileURL)
        }

        func hasTranscript() -> Bool {
            guard let fileURL else { return false }
            return VoiceMemoTranscriptReader.hasTranscript(at: fileURL)
        }

        static let displayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()
    }

    private struct RecordingPage {
        let rows: [RecordingRow]
        let total: Int
    }

    private struct VoiceMemoStoreFailure: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    // MARK: - Item building

    private func makeItem(_ row: RecordingRow, transcript: VoiceMemoTranscript?, hasTranscript: Bool) -> DataItem {
        var metadata = baseMetadata(row)
        metadata["has_transcript"] = String(hasTranscript)

        if let transcript {
            metadata["locale"] = transcript.locale
            metadata["segment_count"] = String(transcript.segments.count)
        }

        return DataItem(
            id: row.id,
            title: row.title,
            subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
            kind: "voice_memo",
            source: sourceName,
            preview: transcript.map { StringSanitizer.compact($0.text, limit: 1_200) },
            metadata: metadata
        )
    }

    /// Detail item for `voicememos_read`: the full transcript instead of a snippet.
    private func makeDetailItem(_ row: RecordingRow, transcript: VoiceMemoTranscript?) -> DataItem {
        var metadata = baseMetadata(row)
        metadata["has_transcript"] = String(transcript != nil)

        if let transcript {
            metadata["locale"] = transcript.locale
            metadata["segment_count"] = String(transcript.segments.count)
        }

        return DataItem(
            id: row.id,
            title: row.title,
            subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
            kind: "voice_memo",
            source: sourceName,
            preview: transcript?.text,
            metadata: metadata
        )
    }

    private func baseMetadata(_ row: RecordingRow) -> [String: String] {
        var metadata: [String: String] = [
            "filename": row.filename,
            "duration_seconds": String(format: "%.1f", row.duration),
            "duration": VoiceMemoTranscriptReader.timecode(row.duration)
        ]

        if let date = row.date {
            metadata["date"] = ISO8601DateFormatter().string(from: date)
        }
        if let label = row.customLabel, !label.isEmpty {
            metadata["label"] = label
        }
        if let fileURL = row.fileURL {
            metadata["path"] = fileURL.path
        } else {
            metadata["available_locally"] = "false"
        }

        if let deletedAt = row.deletedAt {
            metadata["deleted_at"] = ISO8601DateFormatter().string(from: deletedAt)
            metadata["state"] = "recently_deleted"
        }

        return metadata
    }

    private func encodeSegments(_ segments: [VoiceMemoTranscript.Segment], limit: Int = 40_000) -> String? {
        let payload = segments.map { segment -> [String: Any] in
            [
                "text": segment.text,
                "start": segment.start,
                "end": segment.end
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return text.count <= limit ? text : String(text.prefix(limit))
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "aifc", "aiff": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }

    private func fileSize(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return nil
        }
        return values.fileSize
    }

    // MARK: - Store access

    private func locateStore() throws -> RecordingStore {
        let home = fileManager.homeDirectoryForCurrentUser

        for relativePath in libraryPaths {
            let recordings = home.appendingPathComponent(relativePath, isDirectory: true)
            let database = recordings.appendingPathComponent(databaseName, isDirectory: false)
            if fileManager.fileExists(atPath: database.path) {
                return RecordingStore(recordings: recordings, database: database)
            }
        }

        let primary = home.appendingPathComponent(libraryPaths[0], isDirectory: true)
        if fileManager.fileExists(atPath: primary.path) {
            throw VoiceMemoStoreFailure("The Voice Memos recordings folder exists, but \(databaseName) is missing. Open Voice Memos once so macOS creates its store.")
        }

        throw VoiceMemoStoreFailure("The Voice Memos store was not found below \(primary.path). Open Voice Memos at least once, and grant Full Disk Access to M3MCP if the folder is protected.")
    }

    private func loadRecording(id: String) throws -> RecordingRow {
        let store = try locateStore()
        return try withDatabase(at: store.database) { database -> RecordingRow in
            guard let row = try readRecording(database: database, store: store, id: id) else {
                throw VoiceMemoStoreFailure("No voice memo with id \(id). Run voicememos_search to list current ids.")
            }
            return row
        }
    }

    private func readRecordings(
        database: OpaquePointer,
        store: RecordingStore,
        titleQuery: String,
        sinceDays: Int,
        limit: Int,
        offset: Int
    ) throws -> RecordingPage {
        let schema = try recordingSchema(database: database)

        var conditions: [String] = []
        var textBindings: [String] = []
        var dateBinding: Double?

        // Rows without a file name are placeholders the Voice Memos UI does not show either.
        if let pathColumn = schema.path {
            conditions.append("(\(quote(pathColumn)) IS NOT NULL AND TRIM(\(quote(pathColumn))) != '')")
        }

        // ZEVICTIONDATE marks the start of the Recently Deleted window, not an iCloud eviction.
        if let evictionColumn = schema.evictionDate {
            conditions.append("\(quote(evictionColumn)) IS NULL")
        }

        if !titleQuery.isEmpty {
            var titleConditions: [String] = []
            for column in [schema.label, schema.title, schema.path].compactMap({ $0 }) {
                titleConditions.append("\(quote(column)) LIKE ?")
                textBindings.append("%\(titleQuery)%")
            }
            if !titleConditions.isEmpty {
                conditions.append("(\(titleConditions.joined(separator: " OR ")))")
            }
        }

        if sinceDays > 0, let dateColumn = schema.date {
            let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86_400)
            conditions.append("\(quote(dateColumn)) >= ?")
            dateBinding = cutoff.timeIntervalSinceReferenceDate
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let orderColumn = schema.date ?? "Z_PK"
        let selectList = selectClause(for: schema)

        let total = try countRecordings(
            database: database,
            whereClause: whereClause,
            textBindings: textBindings,
            dateBinding: dateBinding
        )

        let sql = """
        SELECT \(selectList)
        FROM ZCLOUDRECORDING
        \(whereClause)
        ORDER BY \(quote(orderColumn)) DESC
        LIMIT ? OFFSET ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VoiceMemoStoreFailure("Could not query the Voice Memos store: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for value in textBindings {
            sqlite3_bind_text(statement, bindIndex, value, -1, transientDestructor())
            bindIndex += 1
        }
        if let dateBinding {
            sqlite3_bind_double(statement, bindIndex, dateBinding)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(offset))

        var rows: [RecordingRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(makeRow(statement: statement, store: store))
        }

        return RecordingPage(rows: rows, total: total)
    }

    private func countRecordings(
        database: OpaquePointer,
        whereClause: String,
        textBindings: [String],
        dateBinding: Double?
    ) throws -> Int {
        let sql = "SELECT COUNT(*) FROM ZCLOUDRECORDING \(whereClause)"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VoiceMemoStoreFailure("Could not count voice memos: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for value in textBindings {
            sqlite3_bind_text(statement, bindIndex, value, -1, transientDestructor())
            bindIndex += 1
        }
        if let dateBinding {
            sqlite3_bind_double(statement, bindIndex, dateBinding)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func readRecording(database: OpaquePointer, store: RecordingStore, id: String) throws -> RecordingRow? {
        let schema = try recordingSchema(database: database)
        let selectList = selectClause(for: schema)

        let sql = "SELECT \(selectList) FROM ZCLOUDRECORDING WHERE Z_PK = ? LIMIT 1"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VoiceMemoStoreFailure("Could not query the Voice Memos store: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, transientDestructor())

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return makeRow(statement: statement, store: store)
    }

    private func makeRow(statement: OpaquePointer, store: RecordingStore) -> RecordingRow {
        let id = textValue(statement, column: 0) ?? String(sqlite3_column_int64(statement, 0))
        let path = textValue(statement, column: 1) ?? ""
        let label = textValue(statement, column: 2)
        let storedTitle = textValue(statement, column: 3)
        let date = dateValue(statement, column: 4)
        let duration = doubleValue(statement, column: 5) ?? 0
        let deletedAt = dateValue(statement, column: 6)

        let filename = path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent
        let fileURL = resolveRecording(path: path, store: store)

        let fallbackTitle = filename.isEmpty
            ? "Voice Memo \(id)"
            : URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent

        let title = [label, storedTitle]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? fallbackTitle

        return RecordingRow(
            id: id,
            title: StringSanitizer.compact(title, limit: 200),
            customLabel: label,
            date: date,
            duration: duration,
            filename: filename,
            fileURL: fileURL,
            deletedAt: deletedAt
        )
    }

    /// `ZPATH` is normally a bare filename, but older stores wrote absolute paths.
    private func resolveRecording(path: String, store: RecordingStore) -> URL? {
        guard !path.isEmpty else {
            return nil
        }

        if path.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: path)
            if fileManager.fileExists(atPath: absolute.path) {
                return absolute
            }
        }

        let filename = URL(fileURLWithPath: path).lastPathComponent
        let candidate = store.recordings.appendingPathComponent(filename, isDirectory: false)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private struct RecordingSchema {
        let path: String?
        let label: String?
        let title: String?
        let date: String?
        let duration: String?
        let evictionDate: String?
    }

    private func selectClause(for schema: RecordingSchema) -> String {
        [
            quote("Z_PK"),
            schema.path.map(quote) ?? "NULL",
            schema.label.map(quote) ?? "NULL",
            schema.title.map(quote) ?? "NULL",
            schema.date.map(quote) ?? "NULL",
            schema.duration.map(quote) ?? "NULL",
            schema.evictionDate.map(quote) ?? "NULL"
        ].joined(separator: ", ")
    }

    private func recordingSchema(database: OpaquePointer) throws -> RecordingSchema {
        let columns = try tableColumns(database: database, table: "ZCLOUDRECORDING")
        guard !columns.isEmpty else {
            throw VoiceMemoStoreFailure("The Voice Memos store does not contain a ZCLOUDRECORDING table.")
        }

        return RecordingSchema(
            path: pick(columns, ["ZPATH", "ZUNIQUEID"]),
            label: pick(columns, ["ZCUSTOMLABEL", "ZCUSTOMLABELFORSORTING"]),
            title: pick(columns, ["ZENCRYPTEDTITLE", "ZTITLE"]),
            date: pick(columns, ["ZDATE", "ZCREATIONDATE"]),
            duration: pick(columns, ["ZDURATION"]),
            evictionDate: pick(columns, ["ZEVICTIONDATE"])
        )
    }

    // MARK: - SQLite helpers

    /// Runs `body` against a private copy of the store.
    ///
    /// `CloudRecordings.db` runs in WAL mode, and the log routinely holds the newest recordings.
    /// Opening the live file read-only cannot replay that log — SQLite either fails to create the
    /// `-shm` file or silently answers from the main database alone, which hides every memo that has
    /// not been checkpointed yet. Copying the file set and opening the copy read-write lets SQLite
    /// replay the log without ever writing to the user's store.
    private func withDatabase<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        let snapshot = try makeSnapshot(of: url)
        defer { try? fileManager.removeItem(at: snapshot.directory) }

        var database: OpaquePointer?
        let status = sqlite3_open_v2(snapshot.database.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)

        guard status == SQLITE_OK, let database else {
            let message = database.map(databaseMessage) ?? "OSStatus \(status)"
            if let database {
                sqlite3_close(database)
            }
            throw VoiceMemoStoreFailure("Cannot read the Voice Memos store. Grant Full Disk Access to M3MCP, then restart the app. Detail: \(message)")
        }

        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 800)
        return try body(database)
    }

    private struct StoreSnapshot {
        let directory: URL
        let database: URL
    }

    /// Copies the store plus its write-ahead log into a private directory.
    private func makeSnapshot(of url: URL) throws -> StoreSnapshot {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("M3MCP-VoiceMemos-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw VoiceMemoStoreFailure("Cannot prepare a temporary copy of the Voice Memos store: \(error.localizedDescription)")
        }

        let database = directory.appendingPathComponent(url.lastPathComponent, isDirectory: false)

        do {
            try fileManager.copyItem(at: url, to: database)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw VoiceMemoStoreFailure("Cannot read the Voice Memos store at \(url.path). Grant Full Disk Access to M3MCP, then restart the app. Detail: \(error.localizedDescription)")
        }

        // The sidecars are optional: they only exist while the store has uncheckpointed changes.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else { continue }
            try? fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: database.path + suffix))
        }

        return StoreSnapshot(directory: directory, database: database)
    }

    private func tableColumns(database: OpaquePointer, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VoiceMemoStoreFailure("Could not inspect the Voice Memos schema: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = textValue(statement, column: 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func pick(_ columns: Set<String>, _ names: [String]) -> String? {
        for name in names where columns.contains(name) {
            return name
        }
        return nil
    }

    private func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func textValue(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else {
            return nil
        }
        return String(cString: value)
    }

    private func doubleValue(_ statement: OpaquePointer, column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, column)
    }

    /// Core Data stores timestamps as seconds since 2001-01-01, so they map onto the reference date.
    private func dateValue(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard let value = doubleValue(statement, column), value != 0 else {
            return nil
        }

        if value > 1_000_000_000 {
            return Date(timeIntervalSince1970: value)
        }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    private func databaseMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private func transientDestructor() -> sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
