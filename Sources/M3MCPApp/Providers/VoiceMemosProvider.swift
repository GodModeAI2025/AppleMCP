import Foundation
import M3MCPCore
import SQLite3

/// Reads Apple Voice Memos from its local Core Data store.
///
/// Voice Memos exposes no supported read API on macOS: it is not AppleScript-scriptable, its
/// framework is private, and its App Intents surface can start a recording but cannot enumerate
/// or read one back. What it does keep is a Core Data store in a group container, readable with
/// Full Disk Access — the same permission `MailProvider` already needs for the Envelope Index.
final class VoiceMemosProvider {
    private let fileManager = FileManager.default

    /// Core Data stores timestamps as seconds since 2001-01-01.
    private static let coreDataEpochOffset: TimeInterval = 978_307_200

    private static let storeRelativePath = "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"

    private struct Recording {
        let id: String
        let title: String
        let date: Date?
        let duration: Double?
        let fileName: String?
        let audioURL: URL?
        let audioAvailable: Bool
        /// When set, the memo sits in Recently Deleted.
        ///
        /// Despite its name, `ZEVICTIONDATE` is the deletion timestamp, not an iCloud
        /// audio-eviction marker. Verified by deleting a memo and diffing the store: the field went
        /// from NULL to "now" while `ZFLAGS` stayed put, `ZFOLDER` stayed NULL, and the audio file
        /// remained on disk. It marks the start of the ~30 day window before Voice Memos purges it.
        let deletedAt: Date?
        let digest: String?
        let folderName: String?
    }

    // MARK: - Tools

    func search(input: [String: JSONValue]) async -> ToolResponse {
        let query = input.string("query").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, min(input.int("limit", default: 20), 50))
        // Minutes exist for short polling intervals: a loop running every few minutes with
        // since_hours=1 would re-fetch the same memos on every pass.
        let sinceMinutes = max(0, input.int("since_minutes", default: 0))
        let sinceHours = max(0, input.int("since_hours", default: 0))
        let windowMinutes = sinceMinutes > 0 ? sinceMinutes : sinceHours * 60

        do {
            // Recently Deleted memos stay in the store for ~30 days with their audio intact.
            // Returning them would present recordings the user has thrown away as current ones.
            var recordings = try loadRecordings().filter { $0.deletedAt == nil }

            if windowMinutes > 0 {
                let cutoff = Date().addingTimeInterval(-Double(windowMinutes) * 60)
                recordings = recordings.filter { ($0.date ?? .distantPast) >= cutoff }
            }

            if !query.isEmpty {
                recordings = recordings.filter { $0.title.localizedCaseInsensitiveContains(query) }
            }

            let items = recordings.prefix(limit).map { makeItem($0) }
            let message = items.isEmpty
                ? "No matching voice memos found in the local Voice Memos store."
                : nil
            return ToolResponse(ok: true, source: "Voice Memos", items: Array(items), message: message)
        } catch {
            return ToolResponse(ok: false, source: "Voice Memos", message: error.localizedDescription)
        }
    }

    func read(input: [String: JSONValue]) async -> ToolResponse {
        let id = input.string("id").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: "Voice Memos", message: "Missing required argument: id")
        }

        let shouldTranscribe = input.bool("transcribe", default: true)
        let localeIdentifier = input.string("locale")

        do {
            let recordings = try loadRecordings()
            guard let recording = recordings.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                return ToolResponse(ok: false, source: "Voice Memos", message: "No voice memo found with id \(id).")
            }

            // A deleted memo stays reachable by id — its audio is intact — but it is deliberately
            // absent from search, so every response has to say so or the caller will mistake it for
            // a current memo.
            let deletedNotice = recording.deletedAt.map {
                "\"\(recording.title)\" is in Recently Deleted (deleted \(Self.displayFormatter.string(from: $0))) and will be purged by Voice Memos. It is excluded from voicememos_search."
            }
            func notice(_ message: String?) -> String? {
                let parts = [deletedNotice, message].compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }

            guard let audioURL = recording.audioURL, recording.audioAvailable else {
                // Distinct from "not found": the memo is real, the audio just is not on this Mac.
                return ToolResponse(
                    ok: true,
                    source: "Voice Memos",
                    items: [makeItem(recording)],
                    message: notice("\"\(recording.title)\" has no audio on this Mac. iCloud evicts local copies to save space — open it once in Voice Memos.app to download it, then try again.")
                )
            }

            guard shouldTranscribe else {
                return ToolResponse(ok: true, source: "Voice Memos", items: [makeItem(recording)], message: notice(nil))
            }

            if let cached = TranscriptCache.read(digest: recording.digest) {
                return ToolResponse(
                    ok: true,
                    source: "Voice Memos",
                    items: [makeItem(recording, transcript: cached, transcriptCached: true)],
                    message: notice(nil)
                )
            }

            let locale = localeIdentifier.isEmpty ? Locale.current : Locale(identifier: localeIdentifier)

            do {
                let transcript = try await SpeechTranscription.transcribe(url: audioURL, locale: locale)
                TranscriptCache.write(transcript, digest: recording.digest)
                let message = transcript.isEmpty
                    ? "Transcription produced no text — the recording may contain no speech."
                    : nil
                return ToolResponse(
                    ok: true,
                    source: "Voice Memos",
                    items: [makeItem(recording, transcript: transcript)],
                    message: notice(message)
                )
            } catch {
                // Metadata is still worth returning when only the transcription leg failed.
                return ToolResponse(
                    ok: true,
                    source: "Voice Memos",
                    items: [makeItem(recording)],
                    message: notice(error.localizedDescription)
                )
            }
        } catch {
            return ToolResponse(ok: false, source: "Voice Memos", message: error.localizedDescription)
        }
    }

    func accessStatus() -> (state: String, message: String?) {
        do {
            let all = try loadRecordings()
            let live = all.filter { $0.deletedAt == nil }
            let deleted = all.count - live.count
            let withAudio = live.filter(\.audioAvailable).count
            var summary = "Voice Memos store is readable — \(live.count) memo(s), \(withAudio) with local audio."
            if deleted > 0 {
                summary += " \(deleted) in Recently Deleted (excluded)."
            }
            return ("authorized", "\(summary) \(SpeechTranscription.statusDescription)")
        } catch let error as SQLiteStoreFailure {
            return ("manual", error.message)
        } catch {
            return ("manual", error.localizedDescription)
        }
    }

    // MARK: - Store access

    private func locateRecordingsDirectory() throws -> URL {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(Self.storeRelativePath, isDirectory: true)

        // A TCC denial surfaces as "does not exist" here, so the remediation has to cover both.
        guard fileManager.fileExists(atPath: directory.path) else {
            throw SQLiteStoreFailure("Voice Memos store not found at \(directory.path). If Voice Memos is set up on this Mac, grant Full Disk Access to M3MCP and restart the app.")
        }
        return directory
    }

    private func loadRecordings() throws -> [Recording] {
        let directory = try locateRecordingsDirectory()
        let storeURL = directory.appendingPathComponent("CloudRecordings.db")

        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw SQLiteStoreFailure("Voice Memos database not found at \(storeURL.path). Grant Full Disk Access to M3MCP, then restart the app.")
        }

        return try SQLiteSnapshot.withDatabase(at: storeURL) { database in
            let folders = self.readFolderNames(database: database)
            return try self.readRecordings(database: database, directory: directory, folders: folders)
        }
    }

    /// Maps `ZFOLDER.Z_PK` to a folder name.
    ///
    /// Voice Memos models Recently Deleted as a folder, so this is how a deleted memo would be
    /// recognised. On a store with nothing deleted the table is empty. Column names are probed
    /// rather than assumed, since the folder schema is not otherwise observable.
    private func readFolderNames(database: OpaquePointer) -> [Int64: String] {
        let columns = SQLiteSnapshot.tableColumns(database: database, table: "ZFOLDER")
        guard columns.contains("Z_PK") else { return [:] }

        guard let nameColumn = ["ZENCRYPTEDNAME", "ZNAME"].first(where: columns.contains) else { return [:] }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT Z_PK, \(nameColumn) FROM ZFOLDER", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var folders: [Int64: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = sqlite3_column_int64(statement, 0)
            if let name = SQLiteSnapshot.text(statement, column: 1) {
                folders[key] = name
            }
        }
        return folders
    }

    private func readRecordings(database: OpaquePointer, directory: URL, folders: [Int64: String]) throws -> [Recording] {
        let columns = SQLiteSnapshot.tableColumns(database: database, table: "ZCLOUDRECORDING")
        guard !columns.isEmpty else {
            throw SQLiteStoreFailure("Voice Memos database is readable, but the ZCLOUDRECORDING table was not found.")
        }

        let sql = """
        SELECT ZUNIQUEID, ZENCRYPTEDTITLE, ZCUSTOMLABEL, ZDATE, ZDURATION,
               ZPATH, ZEVICTIONDATE, ZAUDIODIGEST, ZFOLDER
        FROM ZCLOUDRECORDING
        ORDER BY ZDATE DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let detail = String(cString: sqlite3_errmsg(database))
            throw SQLiteStoreFailure("Could not query the Voice Memos database: \(detail)")
        }
        defer { sqlite3_finalize(statement) }

        var recordings: [Recording] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = SQLiteSnapshot.text(statement, column: 0) else { continue }

            let fileName = SQLiteSnapshot.text(statement, column: 5)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Rows with no path are placeholders, not recordings — CloudKit sync leaves them
            // behind and every attempt to read one fails. They must never surface as memos.
            guard let fileName, !fileName.isEmpty else { continue }

            let audioURL = directory.appendingPathComponent(fileName)
            let exists = fileManager.fileExists(atPath: audioURL.path)
            let deletedAt = SQLiteSnapshot.double(statement, column: 6).map {
                Date(timeIntervalSince1970: $0 + Self.coreDataEpochOffset)
            }

            let title = [
                SQLiteSnapshot.text(statement, column: 1),
                SQLiteSnapshot.text(statement, column: 2)
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fileName

            let folderKey = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(statement, 8)

            let digest = SQLiteSnapshot.blobHex(statement, column: 7)
            if digest == nil, exists {
                // The transcript cache is keyed on this digest, so a missing one silently disables
                // caching for the memo. Log it, otherwise a repeat-read that stays slow looks like
                // a cache bug rather than absent data.
                AppLogger.log("Voice memo \(id) has audio but no ZAUDIODIGEST — transcript caching disabled for it.")
            }

            recordings.append(
                Recording(
                    id: id,
                    title: title,
                    date: SQLiteSnapshot.double(statement, column: 3).map {
                        Date(timeIntervalSince1970: $0 + Self.coreDataEpochOffset)
                    },
                    duration: SQLiteSnapshot.double(statement, column: 4),
                    fileName: fileName,
                    audioURL: audioURL,
                    audioAvailable: exists,
                    deletedAt: deletedAt,
                    digest: digest,
                    folderName: folderKey.flatMap { folders[$0] }
                )
            )
        }

        return recordings
    }

    // MARK: - Presentation

    private func makeItem(_ recording: Recording, transcript: String? = nil, transcriptCached: Bool = false) -> DataItem {
        var metadata: [String: String] = [
            "audio_available": String(recording.audioAvailable),
            "transcript_cached": String(transcriptCached || TranscriptCache.has(digest: recording.digest))
        ]

        if let date = recording.date {
            metadata["date"] = ISO8601DateFormatter().string(from: date)
        }
        if let duration = recording.duration {
            metadata["duration_seconds"] = String(format: "%.1f", duration)
        }
        if let fileName = recording.fileName {
            metadata["file"] = fileName
        }
        if let folderName = recording.folderName {
            metadata["folder"] = folderName
        }
        if let deletedAt = recording.deletedAt {
            metadata["deleted_at"] = ISO8601DateFormatter().string(from: deletedAt)
        }

        let subtitle = [
            recording.date.map { Self.displayFormatter.string(from: $0) },
            recording.duration.map(Self.formatDuration)
        ]
        .compactMap { $0 }
        .joined(separator: " · ")

        return DataItem(
            id: recording.id,
            title: recording.title,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            kind: "voice_memo",
            source: "Voice Memos",
            preview: transcript ?? (recording.audioAvailable ? nil : "Audio not on this Mac"),
            metadata: metadata
        )
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60
            ? String(format: "%d:%02d", total / 60, total % 60)
            : "\(total)s"
    }
}
