import Darwin
import Foundation
import M3MCPCore
import SQLite3

/// Bounds and validates SQLite values before Mail index data becomes a Swift `String`.
///
/// Full Disk Access makes the Envelope Index an untrusted parser input. SQLite guarantees a
/// terminating NUL for `sqlite3_column_text`, but Mail values may contain an earlier NUL or invalid
/// UTF-8. A length-aware conversion avoids both an unbounded C-string scan and silent truncation.
enum MailSQLiteValuePolicy {
    static let maximumSQLiteValueBytes = 256 * 1_024

    enum Violation: Error, Equatable, LocalizedError {
        case oversized(field: String, bytes: Int, maximum: Int)
        case invalidText(field: String)
        case embeddedNUL(field: String)

        var errorDescription: String? {
            switch self {
            case .oversized(let field, let bytes, let maximum):
                return "Mail index field \(field) is \(bytes) bytes; maximum is \(maximum)."
            case .invalidText(let field):
                return "Mail index field \(field) is not valid UTF-8 text."
            case .embeddedNUL(let field):
                return "Mail index field \(field) contains an embedded NUL byte."
            }
        }
    }

    static func applyConnectionLimit(to database: OpaquePointer) {
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(maximumSQLiteValueBytes))
    }

    static func text(
        _ statement: OpaquePointer,
        column: Int32,
        field: String,
        maximumBytes: Int = maximumSQLiteValueBytes
    ) throws -> String? {
        let type = sqlite3_column_type(statement, column)
        guard type != SQLITE_NULL else { return nil }
        guard type != SQLITE_BLOB else {
            throw Violation.invalidText(field: field)
        }

        // `sqlite3_column_bytes` performs SQLite's bounded UTF-8 conversion for numeric values and
        // reports the exact byte count for TEXT. Check it before constructing any Swift string.
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount >= 0, byteCount <= maximumBytes else {
            throw Violation.oversized(
                field: field,
                bytes: max(0, byteCount),
                maximum: maximumBytes
            )
        }
        guard let bytes = sqlite3_column_text(statement, column) else {
            throw Violation.invalidText(field: field)
        }
        let buffer = UnsafeBufferPointer(start: bytes, count: byteCount)
        guard !buffer.contains(0) else {
            throw Violation.embeddedNUL(field: field)
        }
        guard let value = String(bytes: buffer, encoding: .utf8) else {
            throw Violation.invalidText(field: field)
        }
        return value
    }
}

/// Read-only access to the local Apple Mail store.
///
/// Mail keeps an SQLite index (`Envelope Index`) beside the `.emlx` files, so this provider reads the
/// index directly instead of driving Mail.app through AppleEvents. Every connection is opened
/// `SQLITE_OPEN_READONLY`, and no code path here sends, files, deletes or marks anything.
final class MailProvider {
    /// Stable work boundaries used by the production cancellation checks and by deterministic tests.
    /// The labels deliberately describe phases rather than implementation details so tests do not
    /// need timing races or access to a real Mail store.
    enum CancellationCheckpoint: Equatable {
        case requestBoundary
        case databaseWork
        case sqliteProgress
        case mailboxRow
        case mailboxFilter
        case messageRow
        case recipientRow
        case bodyCandidate
        case emlxSearchEntry
        case bodyParsing
        case responseItem
    }

    typealias CancellationCheck = (CancellationCheckpoint) -> Bool

    private let fileManager = FileManager.default
    private let sourceName = "Mail Local Index"
    private let cancellationCheck: CancellationCheck

    init(cancellationCheck: @escaping CancellationCheck = { _ in Task.isCancelled }) {
        self.cancellationCheck = cancellationCheck
    }

    /// `.emlx` files can contain arbitrarily large attachments. MCP only returns a short text body,
    /// so reading the complete file first is both unnecessary and an easy memory-exhaustion path.
    private static let maximumEmlxBytes = 4 * 1_024 * 1_024
    private static let maximumDecodedBodyBytes = maximumEmlxBytes
    private static let maximumMultipartDepth = 8
    private static let maximumMultipartParts = 128
    private static let maximumEmlxSearchEntries = 50_000
    private static let maximumQueryCharacters = 4_096
    private static let maximumQueryTerms = 64
    private static let maximumMailboxFilterCharacters = 1_024
    static let maximumMailboxRows = 20_000
    private static let maximumListedMailboxes = 1_000
    static let maximumRecipientJoinRows = 20_000
    static let maximumRecipientJoinVMInstructions = 1_000_000
    private static let sqliteProgressInstructionStride: Int32 = 256
    static let maximumReturnedRecipientUTF8Bytes = 64 * 1_024

    /// Leave a full MiB below the bridge's eight-MiB HTTP response ceiling. Mail index strings are
    /// untrusted local data and JSON control-character escaping can expand one scalar to six bytes,
    /// so row/field-count limits alone do not bound the encoded response.
    static let maximumEncodedCollectionResponseBytes = 7 * 1_024 * 1_024
    private static let collectionResponseEnvelopeReserveBytes = 128 * 1_024

    /// Relocates the Mail store root the provider reads, so a synthetic index can stand in for the
    /// real one. Reading `~/Library/Mail` needs Full Disk Access, and a TCC grant follows the
    /// *responsible process*, so a build started from a terminal inherits that terminal's grants —
    /// which makes a development build unable to read real mail even on the machine that owns it.
    /// Without this seam the search behaviour cannot be tested at all.
    ///
    /// Same shape as `M3MCP_SOCKET_DIR`, and read-only like everything else here.
    static let mailRootEnvironmentKey = "M3MCP_MAIL_ROOT"

    private func checkCancellation(_ checkpoint: CancellationCheckpoint) throws {
        if cancellationCheck(checkpoint) {
            throw CancellationError()
        }
    }

    private func cancellationResponse() -> ToolResponse {
        ToolResponse(ok: false, source: sourceName, message: "Mail request was cancelled.")
    }

    // MARK: - Tools

    func search(input: [String: JSONValue]) async -> ToolResponse {
        do {
            try checkCancellation(.requestBoundary)
        } catch {
            return cancellationResponse()
        }

        guard input.string("query").count <= Self.maximumQueryCharacters,
              input.string("mailbox").count <= Self.maximumMailboxFilterCharacters,
              Self.hasBoundedFieldSelector(input["fields"]),
              Self.hasValidFieldSelector(input["fields"]) else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Mail search input is too large. query is limited to \(Self.maximumQueryCharacters) characters, mailbox to \(Self.maximumMailboxFilterCharacters), and fields to the documented four names."
            )
        }
        let requestedMatch = StringSanitizer.lower(input.string("match", default: "all"))
        guard ["all", "any", "phrase"].contains(requestedMatch) else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Mail match must be one of: all, any, phrase."
            )
        }
        let request = SearchRequest(input: input)
        guard request.terms.count <= Self.maximumQueryTerms else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Mail search accepts at most \(Self.maximumQueryTerms) query terms. Use match='phrase' or narrow the query."
            )
        }

        do {
            let indexURL = try locateEnvelopeIndex()
            let mailRoot = indexURL.deletingLastPathComponent().deletingLastPathComponent()
            return try withDatabase(at: indexURL) { database in
                try runSearch(request, database: database, mailRoot: mailRoot)
            }
        } catch is CancellationError {
            return cancellationResponse()
        } catch let failure as MailStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    func listMailboxes(input: [String: JSONValue]) async -> ToolResponse {
        do {
            try checkCancellation(.requestBoundary)
        } catch {
            return cancellationResponse()
        }

        guard input.string("query").count <= Self.maximumMailboxFilterCharacters,
              input.string("role").count <= 64 else {
            return ToolResponse(ok: false, source: sourceName, message: "Mailbox filters are too large.")
        }
        let query = StringSanitizer.lower(input.string("query"))
        let role = StringSanitizer.lower(input.string("role"))

        do {
            let indexURL = try locateEnvelopeIndex()
            let mailboxPage = try withDatabase(at: indexURL) { database in
                try readMailboxPage(database: database)
            }
            let boxes = mailboxPage.rows

            var filtered: [MailboxRow] = []
            filtered.reserveCapacity(boxes.count)
            for box in boxes.values {
                try checkCancellation(.mailboxFilter)
                if !role.isEmpty, box.role != role { continue }
                if !query.isEmpty,
                   !StringSanitizer.lower(box.path).contains(query),
                   !StringSanitizer.lower(box.name).contains(query),
                   !StringSanitizer.lower(box.account).contains(query) {
                    continue
                }
                filtered.append(box)
            }
            try checkCancellation(.mailboxFilter)
            filtered.sort { lhs, rhs in
                if lhs.account != rhs.account { return lhs.account < rhs.account }
                return lhs.path.localizedLowercase < rhs.path.localizedLowercase
            }
            try checkCancellation(.mailboxFilter)

            let listed = Array(filtered.prefix(Self.maximumListedMailboxes))
            var candidateItems: [DataItem] = []
            candidateItems.reserveCapacity(listed.count)
            for box in listed {
                try checkCancellation(.responseItem)
                candidateItems.append(DataItem(
                    id: box.id,
                    title: box.path.isEmpty ? box.name : box.path,
                    subtitle: box.account.isEmpty ? box.role : "\(box.account) · \(box.role)",
                    kind: "mail_mailbox",
                    source: sourceName,
                    preview: box.role,
                    metadata: [
                        "mailbox_id": box.id,
                        "role": box.role,
                        "name": box.name,
                        "path": box.path,
                        "account": box.account,
                        "url": box.url,
                        "message_count": String(box.totalCount ?? 0),
                        "unread_count": String(box.unreadCount ?? 0),
                        "message_count_known": String(box.totalCount != nil)
                    ]
                ))
            }

            return try budgetedCollectionResponse(candidates: candidateItems) { items, responseBudgetCapped in
                let hasMore = mailboxPage.scanCapped || filtered.count > items.count
                let resultLimitCapped = filtered.count > candidateItems.count
                let message: String?
                if mailboxPage.scanCapped {
                    message = "Mail mailbox discovery reached its hard \(Self.maximumMailboxRows)-row scan budget; meta.total is a lower bound and some mailboxes may not have been inspected."
                } else if filtered.isEmpty {
                    message = "No mailboxes matched."
                } else if responseBudgetCapped {
                    message = "The encoded Mail response reached its byte budget; only complete mailboxes were returned. Narrow query or role filters."
                } else if resultLimitCapped {
                    message = "The mailbox result limit was reached. Narrow query or role filters."
                } else {
                    message = nil
                }

                return ToolResponse(
                    ok: true,
                    source: sourceName,
                    items: items,
                    message: message,
                    meta: [
                        "returned": String(items.count),
                        "total": String(filtered.count),
                        "total_exact": String(!mailboxPage.scanCapped),
                        "has_more": String(hasMore),
                        "truncated": String(hasMore),
                        "scan_budget": String(Self.maximumMailboxRows),
                        "scan_capped": String(mailboxPage.scanCapped),
                        "result_limit_capped": String(resultLimitCapped),
                        "response_budget_bytes": String(Self.maximumEncodedCollectionResponseBytes),
                        "response_budget_capped": String(responseBudgetCapped),
                        "role_filter": role,
                        "query": query
                    ]
                )
            }
        } catch is CancellationError {
            return cancellationResponse()
        } catch let failure as MailStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    func accessStatus() -> (state: String, message: String?) {
        do {
            let indexURL = try locateEnvelopeIndex()
            try withDatabase(at: indexURL) { database in
                let columns = try tableColumns(database: database, table: "messages")
                guard !columns.isEmpty else {
                    throw MailStoreFailure("Mail index is readable, but the messages table was not found.")
                }
            }
            return ("authorized", "Local Mail index is readable.")
        } catch let error as MailStoreFailure {
            return ("manual", error.message)
        } catch {
            return ("manual", error.localizedDescription)
        }
    }

    func read(input: [String: JSONValue]) async -> ToolResponse {
        do {
            try checkCancellation(.requestBoundary)
        } catch {
            return cancellationResponse()
        }

        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: "Mail", message: "Missing required argument: id")
        }

        if id.hasPrefix("as:") {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Legacy Mail.app Automation ids are no longer accepted. Run mail_search again and use its numeric local-index id."
            )
        }

        guard M3InputValidation.isCanonicalPositiveDecimal(id) else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Invalid Mail row id. Use the exact id returned by mail_search."
            )
        }

        do {
            let indexURL = try locateEnvelopeIndex()
            let mailRoot = indexURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()

            let detail = try withDatabase(at: indexURL) { database -> MailDetail in
                try readMessageDetail(database: database, rowID: id, mailRoot: mailRoot)
            }

            try checkCancellation(.requestBoundary)
            return try makeDetailResponse(detail)
        } catch is CancellationError {
            return cancellationResponse()
        } catch let failure as MailStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    // MARK: - Request

    /// Everything the caller asked for, resolved once so the SQL builder and the response metadata
    /// cannot disagree about it.
    private struct SearchRequest {
        static let allFields = ["subject", "sender", "recipients", "body"]

        let rawQuery: String
        let query: String
        let queryRewritten: Bool
        let terms: [String]
        let match: String
        let fields: [String]
        let limit: Int
        let offset: Int
        let unreadOnly: Bool
        let sinceHours: Int
        let includeJunk: Bool
        let mailboxFilter: String
        let includeBody: Bool
        let includeRecipients: Bool
        let maxCandidates: Int

        init(input: [String: JSONValue]) {
            rawQuery = input.string("query").trimmingCharacters(in: .whitespacesAndNewlines)

            // The old behaviour read "unread", "heute", "24h" out of the query text and turned them
            // into filters — silently, so `query:"heute"` searched for the literal word AND applied a
            // 24-hour window, and returned nothing. It stays the default because callers rely on it,
            // but it is switchable and the response says whether it fired.
            let autoIntent = input.bool("auto_intent", default: true)
            let intent = autoIntent ? MailProvider.parseQueryIntent(rawQuery) : (rawQuery, false, nil)
            query = intent.0
            queryRewritten = autoIntent && (intent.0 != rawQuery || intent.1 || intent.2 != nil)

            let requested = StringSanitizer.lower(input.string("match", default: "all"))
            match = ["all", "any", "phrase"].contains(requested) ? requested : "all"

            if match == "phrase" {
                terms = query.isEmpty ? [] : [query]
            } else {
                terms = query
                    .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                    .map(String.init)
                    .filter { !$0.isEmpty }
            }

            let asked = MailProvider.stringList(input, "fields") ?? ["subject", "sender", "recipients"]
            let normalised = asked
                .map { StringSanitizer.lower($0) }
                .filter { SearchRequest.allFields.contains($0) }
            fields = normalised.isEmpty ? ["subject", "sender", "recipients"] : normalised

            // 500, not 50. The old ceiling was low enough that a week of mail did not fit in one
            // response, and nothing said so.
            limit = max(1, min(input.int("limit", default: 25), 500))
            offset = max(0, min(input.int("offset", default: 0), 1_000_000))
            unreadOnly = input.bool("unread_only", default: autoIntent ? intent.1 : false)
            sinceHours = max(0, min(input.int("since_hours", default: (autoIntent ? intent.2 : nil) ?? 0), 175_200))
            includeJunk = input.bool("include_junk", default: false)
            mailboxFilter = input.string("mailbox").trimmingCharacters(in: .whitespacesAndNewlines)
            includeBody = input.bool("include_body", default: false)
            includeRecipients = input.bool("include_recipients", default: false)
            maxCandidates = max(limit, min(input.int("max_candidates", default: 500), 5_000))
        }

        var searchesBody: Bool { fields.contains("body") && !terms.isEmpty }
    }

    // MARK: - Search

    private func runSearch(
        _ request: SearchRequest,
        database: OpaquePointer,
        mailRoot: URL
    ) throws -> ToolResponse {
        try checkCancellation(.requestBoundary)
        let schema = try MailSchema(database: database, provider: self)
        let mailboxes = try readMailboxes(database: database)
        var junkMailboxIDs = Set<String>()
        if !request.includeJunk {
            for mailbox in mailboxes.values {
                try checkCancellation(.mailboxFilter)
                if mailbox.role == "junk" {
                    junkMailboxIDs.insert(mailbox.id)
                }
            }
        }

        var selected: Set<String>?
        var mailboxFilterMatched = 0
        if !request.mailboxFilter.isEmpty {
            let matches = try matchMailboxes(request.mailboxFilter, in: mailboxes)
            mailboxFilterMatched = matches.count
            var matchedIDs = Set<String>()
            matchedIDs.reserveCapacity(matches.count)
            for match in matches {
                try checkCancellation(.mailboxFilter)
                matchedIDs.insert(match.id)
            }
            selected = matchedIDs
            if matches.isEmpty {
                return ToolResponse(
                    ok: true,
                    source: sourceName,
                    items: [],
                    message: "No mailbox matches '\(request.mailboxFilter)'. Call mail_list_mailboxes to see the names.",
                    meta: baseMeta(request, schema: schema, mailboxes: mailboxes, total: 0, returned: 0,
                                  totalExact: true, hasMore: false, scanned: 0, scanCapped: false,
                                  responseBudgetCapped: false,
                                  mailboxFilterMatched: 0)
                )
            }
        }

        // A message in Mail's Junk mailbox is not guaranteed to carry the optional per-message junk
        // flag. Enforce the documented default at both levels: subtract known Junk mailboxes from an
        // explicit scope, or exclude them from an all-mailbox search.
        if var scoped = selected, !junkMailboxIDs.isEmpty {
            scoped.subtract(junkMailboxIDs)
            selected = scoped
        }
        let excludedMailboxIDs = selected == nil ? junkMailboxIDs : []

        let clause = try buildWhere(
            request,
            schema: schema,
            mailboxIDs: selected,
            excludedMailboxIDs: excludedMailboxIDs
        )

        // Body matching cannot be expressed in SQL — the text is in the .emlx files. So a body search
        // reads a bounded candidate window and filters it here, and says both things in the metadata:
        // how many rows it looked at, and whether that window was itself cut short.
        if request.searchesBody {
            let candidates = try fetchRows(
                request, schema: schema, clause: clause, database: database,
                limit: request.maxCandidates, offset: 0
            )
            let scanCapped = candidates.count >= request.maxCandidates
            let recipientText = request.fields.contains("recipients") || request.includeRecipients
                ? try readRecipients(database: database, schema: schema, messageIDs: candidates.map { $0.id })
                : [:]

            var matched: [MailRow] = []
            var matchedFields: [String: [String]] = [:]
            var bodies: [String: String] = [:]
            for row in candidates {
                try checkCancellation(.bodyCandidate)
                let body = try loadBody(row: row, mailboxes: mailboxes, mailRoot: mailRoot, database: database)
                let hits = try fieldsMatched(
                    request, row: row, recipients: recipientText[row.id] ?? "", body: body
                )
                guard !hits.isEmpty else { continue }
                matched.append(row)
                matchedFields[row.id] = hits
                if request.includeBody { bodies[row.id] = body }
            }

            let page = Array(matched.dropFirst(request.offset).prefix(request.limit))
            var candidateItems: [DataItem] = []
            candidateItems.reserveCapacity(page.count)
            for row in page {
                try checkCancellation(.responseItem)
                candidateItems.append(makeItem(
                    row,
                    mailboxes: mailboxes,
                    fieldsMatched: matchedFields[row.id] ?? [],
                    recipients: request.includeRecipients ? recipientText[row.id] : nil,
                    bodySnippet: request.includeBody ? bodies[row.id] : nil
                ))
            }

            return try budgetedCollectionResponse(candidates: candidateItems) { items, responseBudgetCapped in
                let hasMore = matched.count > request.offset + items.count
                return ToolResponse(
                    ok: true,
                    source: sourceName,
                    items: items,
                    message: message(
                        items: items,
                        hasMore: hasMore,
                        scanCapped: scanCapped,
                        responseBudgetCapped: responseBudgetCapped,
                        request: request
                    ),
                    meta: baseMeta(request, schema: schema, mailboxes: mailboxes, total: matched.count,
                                   returned: items.count, totalExact: !scanCapped, hasMore: hasMore,
                                   scanned: candidates.count, scanCapped: scanCapped,
                                   responseBudgetCapped: responseBudgetCapped,
                                   mailboxFilterMatched: mailboxFilterMatched)
                )
            }
        }

        let total = try countRows(schema: schema, clause: clause, database: database)
        let rows = try fetchRows(
            request, schema: schema, clause: clause, database: database,
            limit: request.limit, offset: request.offset
        )
        let recipientText = request.fields.contains("recipients") || request.includeRecipients
            ? try readRecipients(database: database, schema: schema, messageIDs: rows.map { $0.id })
            : [:]

        var candidateItems: [DataItem] = []
        candidateItems.reserveCapacity(rows.count)
        for row in rows {
            try checkCancellation(.bodyCandidate)
            var body = ""
            if request.includeBody {
                body = try loadBody(row: row, mailboxes: mailboxes, mailRoot: mailRoot, database: database)
            }
            let hits = try fieldsMatched(
                request,
                row: row,
                recipients: recipientText[row.id] ?? "",
                body: body
            )
            try checkCancellation(.responseItem)
            candidateItems.append(makeItem(
                row,
                mailboxes: mailboxes,
                fieldsMatched: hits,
                recipients: request.includeRecipients ? recipientText[row.id] : nil,
                bodySnippet: request.includeBody ? body : nil
            ))
        }

        return try budgetedCollectionResponse(candidates: candidateItems) { items, responseBudgetCapped in
            let hasMore = total > request.offset + items.count
            return ToolResponse(
                ok: true,
                source: sourceName,
                items: items,
                message: message(
                    items: items,
                    hasMore: hasMore,
                    scanCapped: false,
                    responseBudgetCapped: responseBudgetCapped,
                    request: request
                ),
                meta: baseMeta(request, schema: schema, mailboxes: mailboxes, total: total, returned: items.count,
                               totalExact: true, hasMore: hasMore, scanned: total, scanCapped: false,
                               responseBudgetCapped: responseBudgetCapped,
                               mailboxFilterMatched: mailboxFilterMatched)
            )
        }
    }

    /// The response fields a caller branches on. `message` is prose and gets ignored; a capped result
    /// and a complete one were previously indistinguishable, which is how a scan of a week could
    /// report three days and look like a success.
    private func baseMeta(
        _ request: SearchRequest,
        schema: MailSchema,
        mailboxes: [String: MailboxRow],
        total: Int,
        returned: Int,
        totalExact: Bool,
        hasMore: Bool,
        scanned: Int,
        scanCapped: Bool,
        responseBudgetCapped: Bool,
        mailboxFilterMatched: Int
    ) -> [String: String] {
        [
            "returned": String(returned),
            "offset": String(request.offset),
            "limit": String(request.limit),
            "total": String(total),
            "total_exact": String(totalExact),
            "has_more": String(hasMore),
            "truncated": String(hasMore || scanCapped || responseBudgetCapped),
            "scanned": String(scanned),
            "scan_capped": String(scanCapped),
            "response_budget_bytes": String(Self.maximumEncodedCollectionResponseBytes),
            "response_budget_capped": String(responseBudgetCapped),
            "fields": request.fields.joined(separator: ","),
            "match": request.match,
            "query": request.query,
            "query_rewritten": String(request.queryRewritten),
            "unread_only": String(request.unreadOnly),
            "since_hours": String(request.sinceHours),
            "include_junk": String(request.includeJunk),
            "mailbox_filter": request.mailboxFilter,
            "mailbox_filter_matched": String(mailboxFilterMatched),
            "mailboxes_known": String(mailboxes.count),
            "recipients_searchable": String(schema.canSearchRecipients),
            "body_searchable": "true"
        ]
    }

    private func message(
        items: [DataItem],
        hasMore: Bool,
        scanCapped: Bool,
        responseBudgetCapped: Bool,
        request: SearchRequest
    ) -> String? {
        if responseBudgetCapped {
            return "The encoded Mail response reached its byte budget; only complete messages were returned and meta.has_more is true. Continue with offset \(request.offset + items.count)."
        }
        if items.isEmpty {
            if request.offset > 0 {
                return "No messages at offset \(request.offset). Lower offset, or read meta.total."
            }
            return "No matching messages found in the local Mail index."
        }
        if scanCapped {
            return "Body search inspected \(request.maxCandidates) candidate messages; meta.scan_capped is true and meta.total is a lower bound. Raise max_candidates to search further back."
        }
        if hasMore {
            return "meta.has_more is true: this is not the whole result set. Page with offset."
        }
        return nil
    }

    /// Selects a stable prefix of complete items whose final `ToolResponse` stays below the local
    /// transport ceiling. Individual encodings are measured once, avoiding quadratic re-encoding of
    /// a hostile 500/1,000-item page. The final response is measured as a safety check because its
    /// metadata and prose depend on the selected count.
    private func budgetedCollectionResponse(
        candidates: [DataItem],
        makeResponse: (_ items: [DataItem], _ responseBudgetCapped: Bool) -> ToolResponse
    ) throws -> ToolResponse {
        let itemPayloadBudget = Self.maximumEncodedCollectionResponseBytes
            - Self.collectionResponseEnvelopeReserveBytes
        var selected: [DataItem] = []
        selected.reserveCapacity(candidates.count)
        var encodedItemBytes = 0

        for item in candidates {
            try checkCancellation(.responseItem)
            guard let encoded = try? M3JSON.makeEncoder().encode(item) else { break }
            let separatorBytes = selected.isEmpty ? 0 : 1
            guard encodedItemBytes + separatorBytes + encoded.count <= itemPayloadBudget else { break }
            encodedItemBytes += separatorBytes + encoded.count
            selected.append(item)
        }

        var responseBudgetCapped = selected.count < candidates.count
        try checkCancellation(.responseItem)
        var response = makeResponse(selected, responseBudgetCapped)
        while let encoded = try? M3JSON.makeEncoder().encode(response),
              encoded.count > Self.maximumEncodedCollectionResponseBytes,
              !selected.isEmpty {
            try checkCancellation(.responseItem)
            selected.removeLast()
            responseBudgetCapped = true
            response = makeResponse(selected, responseBudgetCapped)
        }

        try checkCancellation(.responseItem)
        if let encoded = try? M3JSON.makeEncoder().encode(response),
           encoded.count <= Self.maximumEncodedCollectionResponseBytes {
            return response
        }

        // Validated Mail inputs keep the empty envelope far below this path. Keep the transport
        // contract fail-closed even if a future metadata field accidentally invalidates that bound.
        return ToolResponse(
            ok: false,
            source: sourceName,
            message: "Mail response metadata exceeded the local transport byte budget. Narrow the request."
        )
    }

    // MARK: - SQL

    /// Column and table names resolved once against whatever schema this machine's Mail happens to
    /// have. Nothing here assumes a column exists.
    private struct MailSchema {
        let subject: String?
        let sender: String?
        let messageID: String?
        let date: String?
        let read: String?
        let deleted: String?
        let junk: String?
        let mailbox: String?

        let hasSubjectsLookup: Bool
        let hasAddressesLookup: Bool
        let addressComment: String?

        let recipientsMessageColumn: String?
        let recipientsAddressColumn: String?

        init(database: OpaquePointer, provider: MailProvider) throws {
            let columns = try provider.tableColumns(database: database, table: "messages")
            guard !columns.isEmpty else {
                throw MailStoreFailure("Mail index is readable, but the messages table was not found.")
            }

            subject = provider.pick(columns, ["subject"])
            sender = provider.pick(columns, ["sender"])
            messageID = provider.pick(columns, ["message_id", "messageid"])
            date = provider.pick(columns, ["date_received", "dateReceived", "date_sent", "dateSent", "date_created"])
            read = provider.pick(columns, ["read", "is_read", "isRead"])
            deleted = provider.pick(columns, ["deleted", "is_deleted", "isDeleted"])
            junk = provider.pick(columns, ["junk", "is_junk", "isJunk"])
            mailbox = provider.pick(columns, ["mailbox"])

            let subjects = try provider.tableColumns(database: database, table: "subjects")
            let addresses = try provider.tableColumns(database: database, table: "addresses")
            hasSubjectsLookup = subjects.contains("subject") && subject != nil
            hasAddressesLookup = addresses.contains("address") && sender != nil
            addressComment = hasAddressesLookup && addresses.contains("comment") ? "comment" : nil

            let recipients = try provider.tableColumns(database: database, table: "recipients")
            if recipients.isEmpty || !addresses.contains("address") {
                recipientsMessageColumn = nil
                recipientsAddressColumn = nil
            } else {
                recipientsMessageColumn = provider.pick(recipients, ["message"])
                recipientsAddressColumn = provider.pick(recipients, ["address"])
            }
        }

        var canSearchRecipients: Bool {
            recipientsMessageColumn != nil && recipientsAddressColumn != nil
        }

        /// What to *show* as the sender: a display name when there is one.
        var senderDisplayExpression: String {
            guard hasAddressesLookup else {
                return sender.map { "messages.\(MailProvider.quoted($0))" } ?? "''"
            }
            if let comment = addressComment {
                return "COALESCE(addresses.\(MailProvider.quoted(comment)), addresses.\(MailProvider.quoted("address")), '')"
            }
            return "COALESCE(addresses.\(MailProvider.quoted("address")), '')"
        }

        /// What to *match* the sender against: the display name AND the address.
        ///
        /// Using one expression for both was the bug. `COALESCE(comment, address)` shows the better
        /// string and searches the worse one: any address behind a display name became unsearchable,
        /// which is why a `firstname.lastname` query found nothing unless the address happened to
        /// appear in a subject line.
        var senderMatchExpression: String {
            guard hasAddressesLookup else { return senderDisplayExpression }
            guard let comment = addressComment else {
                return "COALESCE(addresses.\(MailProvider.quoted("address")), '')"
            }
            return "(COALESCE(addresses.\(MailProvider.quoted(comment)), '') || ' ' || COALESCE(addresses.\(MailProvider.quoted("address")), ''))"
        }

        var subjectExpression: String {
            if hasSubjectsLookup { return "subjects.\(MailProvider.quoted("subject"))" }
            return subject.map { "messages.\(MailProvider.quoted($0))" } ?? "''"
        }

        var joins: [String] {
            var out: [String] = []
            if hasSubjectsLookup, let subject {
                out.append("LEFT JOIN subjects ON messages.\(MailProvider.quoted(subject)) = subjects.ROWID")
            }
            if hasAddressesLookup, let sender {
                out.append("LEFT JOIN addresses ON messages.\(MailProvider.quoted(sender)) = addresses.ROWID")
            }
            return out
        }
    }

    private struct WhereClause {
        let sql: String
        let bindings: [String]
    }

    private func buildWhere(
        _ request: SearchRequest,
        schema: MailSchema,
        mailboxIDs: Set<String>?,
        excludedMailboxIDs: Set<String>
    ) throws -> WhereClause {
        try checkCancellation(.databaseWork)
        var predicates: [String] = []
        var bindings: [String] = []

        if let deleted = schema.deleted {
            predicates.append("(messages.\(Self.quoted(deleted)) = 0 OR messages.\(Self.quoted(deleted)) IS NULL)")
        }

        if !request.includeJunk, let junk = schema.junk {
            predicates.append("(messages.\(Self.quoted(junk)) = 0 OR messages.\(Self.quoted(junk)) IS NULL)")
        }

        if request.unreadOnly {
            guard let read = schema.read else {
                throw MailStoreFailure("Unread filtering is not available in this Mail index schema.")
            }
            predicates.append("messages.\(Self.quoted(read)) = 0")
        }

        // In SQL, not after the LIMIT. Filtering a already-truncated page in memory is only correct
        // while the ORDER BY happens to be the same column, and silently wrong the moment it is not.
        if request.sinceHours > 0, let date = schema.date {
            let cutoff = Date().addingTimeInterval(-Double(request.sinceHours) * 3_600)
            let epoch = cutoff.timeIntervalSince1970
            let reference = cutoff.timeIntervalSinceReferenceDate
            predicates.append(
                "((messages.\(Self.quoted(date)) > 1000000000 AND messages.\(Self.quoted(date)) >= \(epoch))"
                + " OR (messages.\(Self.quoted(date)) <= 1000000000 AND messages.\(Self.quoted(date)) >= \(reference)))"
            )
        }

        if let mailboxIDs, let mailbox = schema.mailbox {
            if mailboxIDs.isEmpty {
                predicates.append("0 = 1")
            } else {
                let sorted = mailboxIDs.sorted()
                try checkCancellation(.databaseWork)
                let list = sorted.map { _ in "?" }.joined(separator: ",")
                predicates.append("messages.\(Self.quoted(mailbox)) IN (\(list))")
                bindings.append(contentsOf: sorted)
            }
        }

        if !excludedMailboxIDs.isEmpty, let mailbox = schema.mailbox {
            let sorted = excludedMailboxIDs.sorted()
            try checkCancellation(.databaseWork)
            let list = sorted.map { _ in "?" }.joined(separator: ",")
            predicates.append(
                "(messages.\(Self.quoted(mailbox)) IS NULL OR messages.\(Self.quoted(mailbox)) NOT IN (\(list)))"
            )
            bindings.append(contentsOf: sorted)
        }

        // One clause per term, ORed across the requested fields and ANDed across the terms — so
        // "Graph API" means both words somewhere in the scoped fields rather than that exact string,
        // which returned nothing.
        // If body is among the requested alternatives, no term predicate belongs in SQL: applying
        // only the index-backed alternatives here would discard body-only hits before their .emlx
        // files can be inspected. The structural/status predicates above still bound that scan.
        if !request.terms.isEmpty, !request.searchesBody {
            var termClauses: [String] = []
            for term in request.terms {
                try checkCancellation(.databaseWork)
                var fieldClauses: [String] = []
                let pattern = "%\(term.localizedLowercase)%"

                if request.fields.contains("subject") {
                    fieldClauses.append("lower(\(schema.subjectExpression)) LIKE ?")
                    bindings.append(pattern)
                }
                if request.fields.contains("sender") {
                    fieldClauses.append("lower(\(schema.senderMatchExpression)) LIKE ?")
                    bindings.append(pattern)
                }
                if request.fields.contains("recipients"), schema.canSearchRecipients,
                   let messageColumn = schema.recipientsMessageColumn,
                   let addressColumn = schema.recipientsAddressColumn {
                    fieldClauses.append("""
                    EXISTS (
                      SELECT 1 FROM recipients AS r
                      JOIN addresses AS ra ON r.\(Self.quoted(addressColumn)) = ra.ROWID
                      WHERE r.\(Self.quoted(messageColumn)) = messages.ROWID
                        AND lower(COALESCE(ra.\(Self.quoted("comment")), '') || ' ' || COALESCE(ra.\(Self.quoted("address")), '')) LIKE ?
                    )
                    """)
                    bindings.append(pattern)
                }

                if fieldClauses.isEmpty { continue }
                termClauses.append("(" + fieldClauses.joined(separator: " OR ") + ")")
            }

            if !termClauses.isEmpty {
                let joiner = request.match == "any" ? " OR " : " AND "
                predicates.append("(" + termClauses.joined(separator: joiner) + ")")
            } else {
                // Every requested field is unavailable in this schema. Returning everything would be
                // a silent lie about what was searched.
                predicates.append("0 = 1")
            }
        }

        let sql = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        return WhereClause(sql: sql, bindings: bindings)
    }

    private func countRows(schema: MailSchema, clause: WhereClause, database: OpaquePointer) throws -> Int {
        var sql = "SELECT count(*) FROM messages"
        for join in schema.joins { sql += " " + join }
        sql += clause.sql

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MailStoreFailure("Could not count Mail index rows: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        try bind(clause.bindings, to: statement, from: 1)
        let status = try checkedSQLiteStep(statement, database: database, checkpoint: .databaseWork)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { return 0 }
            throw MailStoreFailure("Could not count Mail index rows: \(databaseMessage(database))")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func fetchRows(
        _ request: SearchRequest,
        schema: MailSchema,
        clause: WhereClause,
        database: OpaquePointer,
        limit: Int,
        offset: Int
    ) throws -> [MailRow] {
        let dateExpr = schema.date.map { "messages.\(Self.quoted($0))" }
        let messageIDExpr = schema.messageID.map { "messages.\(Self.quoted($0))" } ?? "NULL"
        let readExpr = schema.read.map { "messages.\(Self.quoted($0))" } ?? "NULL"
        let mailboxExpr = schema.mailbox.map { "messages.\(Self.quoted($0))" } ?? "NULL"

        var sql = """
        SELECT
          messages.ROWID,
          \(messageIDExpr),
          \(schema.subjectExpression),
          \(schema.senderDisplayExpression),
          \(dateExpr ?? "NULL"),
          \(readExpr),
          \(mailboxExpr),
          \(schema.senderMatchExpression)
        FROM messages
        """
        for join in schema.joins { sql += " " + join }
        sql += clause.sql
        // ROWID breaks ties. Without it two messages sharing a timestamp can swap places between two
        // pages, so a paged walk both repeats and misses rows.
        sql += " ORDER BY \(dateExpr ?? "messages.ROWID") DESC, messages.ROWID DESC LIMIT ? OFFSET ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MailStoreFailure("Could not query Mail index: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        var index = try bind(clause.bindings, to: statement, from: 1)
        sqlite3_bind_int(statement, index, Int32(limit)); index += 1
        sqlite3_bind_int(statement, index, Int32(offset))

        var rows: [MailRow] = []
        while true {
            let status = try checkedSQLiteStep(statement, database: database, checkpoint: .messageRow)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw MailStoreFailure("Could not query Mail index: \(databaseMessage(database))")
            }
            rows.append(
                MailRow(
                    id: try textValue(statement, column: 0, field: "messages.ROWID") ?? UUID().uuidString,
                    messageID: try textValue(statement, column: 1, field: "messages.message_id")
                        .map { String($0.prefix(2_000)) },
                    subject: StringSanitizer.compact(
                        try textValue(statement, column: 2, field: "messages.subject") ?? "(no subject)",
                        limit: 2_000
                    ),
                    sender: StringSanitizer.compact(
                        try textValue(statement, column: 3, field: "messages.sender") ?? "",
                        limit: 2_000
                    ),
                    receivedDate: dateValue(statement, column: 4),
                    isRead: boolValue(statement, column: 5),
                    mailboxID: try textValue(statement, column: 6, field: "messages.mailbox")
                        .map { String($0.prefix(256)) },
                    senderHaystack: String(
                        (try textValue(statement, column: 7, field: "messages.sender_search") ?? "")
                            .prefix(8_000)
                    )
                )
            )
        }
        return rows
    }

    /// One query for the whole page, so `fields_matched` is measured rather than inferred.
    private func readRecipients(
        database: OpaquePointer,
        schema: MailSchema,
        messageIDs: [String]
    ) throws -> [String: String] {
        guard schema.canSearchRecipients,
              let messageColumn = schema.recipientsMessageColumn,
              let addressColumn = schema.recipientsAddressColumn,
              !messageIDs.isEmpty
        else { return [:] }

        let placeholders = messageIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT r.\(Self.quoted(messageColumn)),
               COALESCE(ra.\(Self.quoted("comment")), '') || ' ' || COALESCE(ra.\(Self.quoted("address")), '')
        FROM recipients AS r
        JOIN addresses AS ra ON r.\(Self.quoted(addressColumn)) = ra.ROWID
        WHERE r.\(Self.quoted(messageColumn)) IN (\(placeholders))
        LIMIT ?
        """

        // LIMIT bounds produced rows, while the progress handler also bounds the VM work needed to
        // find them (a hostile store may omit the usual recipients.message index). Returning an
        // incomplete recipient map would make fields_matched and displayed recipients dishonest, so
        // either ceiling fails the request closed.
        let workContext = SQLiteRecipientWorkContext(
            maximumInstructions: Self.maximumRecipientJoinVMInstructions,
            instructionStride: Self.sqliteProgressInstructionStride,
            isCancelled: { [cancellationCheck] in cancellationCheck(.sqliteProgress) }
        )
        sqlite3_progress_handler(
            database,
            Self.sqliteProgressInstructionStride,
            { rawContext -> Int32 in
                guard let rawContext else { return 0 }
                return Unmanaged<SQLiteRecipientWorkContext>
                    .fromOpaque(rawContext)
                    .takeUnretainedValue()
                    .progress()
            },
            Unmanaged.passUnretained(workContext).toOpaque()
        )
        defer { installCancellationProgressHandler(on: database) }

        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            if workContext.cancellationObserved { throw CancellationError() }
            if workContext.workBudgetExceeded { throw recipientWorkBudgetFailure() }
            throw MailStoreFailure("Could not query Mail recipients: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }
        let limitIndex = try bind(messageIDs, to: statement, from: 1)
        guard sqlite3_bind_int(
            statement,
            limitIndex,
            Int32(Self.maximumRecipientJoinRows + 1)
        ) == SQLITE_OK else {
            throw MailStoreFailure("Could not bind the Mail recipient row budget.")
        }

        var out: [String: String] = [:]
        var processedRows = 0
        while true {
            try checkCancellation(.recipientRow)
            let status = sqlite3_step(statement)
            if status == SQLITE_INTERRUPT {
                if workContext.cancellationObserved { throw CancellationError() }
                if workContext.workBudgetExceeded { throw recipientWorkBudgetFailure() }
                throw CancellationError()
            }
            if cancellationCheck(.recipientRow) { throw CancellationError() }
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw MailStoreFailure("Could not query Mail recipients: \(databaseMessage(database))")
            }
            processedRows += 1
            guard processedRows <= Self.maximumRecipientJoinRows else {
                throw MailStoreFailure(
                    "Mail recipient lookup exceeded its hard row safety budget of \(Self.maximumRecipientJoinRows) rows. Narrow the search, reduce limit/max_candidates, or omit recipients."
                )
            }
            guard let key = try textValue(statement, column: 0, field: "recipients.message") else { continue }
            let value = String(
                (try textValue(statement, column: 1, field: "recipients.address") ?? "")
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(1_024)
            )
            guard !value.isEmpty else { continue }
            let combined = out[key].map { "\($0), \(value)" } ?? value
            out[key] = String(combined.prefix(4_096))
        }
        return out
    }

    /// Which of the requested fields actually carried the match, per item. The point is that a caller
    /// can tell an address hit from a subject coincidence — the distinction the old response lost.
    private func fieldsMatched(
        _ request: SearchRequest,
        row: MailRow,
        recipients: String,
        body: String
    ) throws -> [String] {
        try checkCancellation(.bodyCandidate)
        guard !request.terms.isEmpty else { return [] }

        let haystacks: [(String, String)] = [
            ("subject", StringSanitizer.lower(row.subject)),
            ("sender", StringSanitizer.lower(row.senderHaystack.isEmpty ? row.sender : row.senderHaystack)),
            ("recipients", StringSanitizer.lower(recipients)),
            ("body", StringSanitizer.lower(body))
        ].filter { request.fields.contains($0.0) }
        let lowered = request.terms.map { StringSanitizer.lower($0) }.filter { !$0.isEmpty }
        guard !lowered.isEmpty else { return [] }

        let isMatch: Bool
        if request.match == "any" {
            isMatch = lowered.contains { term in haystacks.contains { $0.1.contains(term) } }
        } else {
            // `phrase` has one term. For `all`, each term may occur in a different requested field,
            // matching buildWhere's term-wise OR-across-fields semantics.
            isMatch = lowered.allSatisfy { term in haystacks.contains { $0.1.contains(term) } }
        }
        try checkCancellation(.bodyCandidate)
        guard isMatch else { return [] }

        return haystacks.compactMap { name, haystack in
            lowered.contains(where: haystack.contains) ? name : nil
        }
    }

    // MARK: - Mailboxes

    private struct MailboxRow {
        let id: String
        let url: String
        let name: String
        let path: String
        let account: String
        let role: String
        let totalCount: Int?
        let unreadCount: Int?
    }

    private struct MailboxPage {
        let rows: [String: MailboxRow]
        let scanCapped: Bool
    }

    private func readMailboxes(database: OpaquePointer) throws -> [String: MailboxRow] {
        let page = try readMailboxPage(database: database)
        guard !page.scanCapped else {
            throw MailStoreFailure(
                "Mail mailbox discovery exceeded its hard row safety budget of \(Self.maximumMailboxRows) rows."
            )
        }
        return page.rows
    }

    private func readMailboxPage(database: OpaquePointer) throws -> MailboxPage {
        let columns = try tableColumns(database: database, table: "mailboxes")
        guard let urlColumn = pick(columns, ["url"]) else {
            return MailboxPage(rows: [:], scanCapped: false)
        }

        let totalColumn = pick(columns, ["total_count", "totalCount", "message_count"])
        let unreadColumn = pick(columns, ["unread_count", "unreadCount", "unread"])

        let sql = """
        SELECT ROWID, \(Self.quoted(urlColumn)),
               \(totalColumn.map { Self.quoted($0) } ?? "NULL"),
               \(unreadColumn.map { Self.quoted($0) } ?? "NULL")
        FROM mailboxes
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return MailboxPage(rows: [:], scanCapped: false)
        }
        defer { sqlite3_finalize(statement) }

        var out: [String: MailboxRow] = [:]
        var scanCapped = false
        while true {
            let status = try checkedSQLiteStep(statement, database: database, checkpoint: .mailboxRow)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw MailStoreFailure("Could not query Mail mailboxes: \(databaseMessage(database))")
            }
            guard out.count < Self.maximumMailboxRows else {
                scanCapped = true
                break
            }
            guard let id = try textValue(statement, column: 0, field: "mailboxes.ROWID") else { continue }
            let raw = String(
                (try textValue(statement, column: 1, field: "mailboxes.url") ?? "")
                    .prefix(4_096)
            )
            let parts = Self.describeMailbox(url: raw)
            out[id] = MailboxRow(
                id: id,
                url: raw,
                name: parts.name,
                path: parts.path,
                account: parts.account,
                role: parts.role,
                totalCount: intValue(statement, column: 2),
                unreadCount: intValue(statement, column: 3)
            )
        }
        return MailboxPage(rows: out, scanCapped: scanCapped)
    }

    /// Mailbox urls look like `imap://user@host/Sent%20Messages` or a plain path for a local store, so
    /// the role has to come out of the last component rather than a column — the index has no role
    /// field. Unknown names are `folder`, never guessed into a role.
    static func describeMailbox(url raw: String) -> (name: String, path: String, account: String, role: String) {
        var account = ""
        var path = raw

        if let parsed = URL(string: raw), let scheme = parsed.scheme, !scheme.isEmpty, scheme != "file" {
            let user = parsed.user.map { "\($0)@" } ?? ""
            account = "\(user)\(parsed.host ?? "")"
            path = parsed.path
        } else if raw.hasPrefix("file://"), let parsed = URL(string: raw) {
            path = parsed.path
        }

        let decoded = (path.removingPercentEncoding ?? path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = decoded.split(separator: "/").last.map(String.init) ?? decoded

        let roles: [(String, [String])] = [
            ("inbox", ["inbox", "eingang", "posteingang"]),
            ("sent", ["sent", "sent messages", "sent items", "gesendet", "gesendete objekte", "gesendete elemente"]),
            ("drafts", ["drafts", "entwürfe", "entwuerfe"]),
            ("archive", ["archive", "archiv", "all mail", "alle nachrichten"]),
            ("junk", ["junk", "junk email", "junk e-mail", "spam", "werbung"]),
            ("trash", ["trash", "deleted messages", "deleted items", "papierkorb", "gelöschte objekte"])
        ]
        let needle = StringSanitizer.lower(name)
        let role = roles.first { $0.1.contains(needle) }?.0 ?? "folder"

        return (name: name, path: decoded, account: account, role: role)
    }

    /// Matches on id, whole path, name, or a case-insensitive substring of either — in that order of
    /// specificity, so `mailbox:"Archive"` does not silently also pull in "Archive/2019/Invoices"
    /// when an exact "Archive" exists.
    private func matchMailboxes(_ filter: String, in boxes: [String: MailboxRow]) throws -> [MailboxRow] {
        let needle = StringSanitizer.lower(filter)
        let all = Array(boxes.values)

        if let exactID = boxes[filter] { return [exactID] }

        var exactPath: [MailboxRow] = []
        var exactName: [MailboxRow] = []
        var byRole: [MailboxRow] = []
        var substringMatches: [MailboxRow] = []
        for box in all {
            try checkCancellation(.mailboxFilter)
            let path = StringSanitizer.lower(box.path)
            let name = StringSanitizer.lower(box.name)
            if path == needle { exactPath.append(box) }
            if name == needle { exactName.append(box) }
            if box.role == needle { byRole.append(box) }
            if path.contains(needle) || name.contains(needle) { substringMatches.append(box) }
        }

        if !exactPath.isEmpty { return exactPath }
        if !exactName.isEmpty { return exactName }
        if !byRole.isEmpty { return byRole }
        return substringMatches
    }

    // MARK: - Items

    private func makeItem(
        _ row: MailRow,
        mailboxes: [String: MailboxRow],
        fieldsMatched: [String],
        recipients: String?,
        bodySnippet: String?
    ) -> DataItem {
        var metadata: [String: String] = ["sender": row.sender]

        if let messageID = row.messageID, !messageID.isEmpty {
            metadata["message_id"] = messageID
        }
        if let receivedDate = row.receivedDate {
            metadata["received"] = ISO8601DateFormatter().string(from: receivedDate)
        }
        if let isRead = row.isRead {
            metadata["read"] = String(isRead)
        }
        if let mailboxID = row.mailboxID, let box = mailboxes[mailboxID] {
            metadata["mailbox_id"] = box.id
            metadata["mailbox"] = box.path.isEmpty ? box.name : box.path
            metadata["mailbox_role"] = box.role
            if !box.account.isEmpty { metadata["account"] = box.account }
        } else {
            metadata["mailbox_role"] = "unknown"
        }
        if !fieldsMatched.isEmpty {
            metadata["fields_matched"] = fieldsMatched.joined(separator: ",")
        }
        if let recipients, !recipients.isEmpty {
            metadata["to"] = recipients
        }

        var preview: String?
        if let bodySnippet, !bodySnippet.isEmpty {
            preview = String(bodySnippet.prefix(400))
        }

        return DataItem(
            id: row.id,
            title: row.subject.isEmpty ? "(no subject)" : row.subject,
            subtitle: row.sender,
            kind: "mail_message",
            source: sourceName,
            preview: preview,
            metadata: metadata
        )
    }

    private func loadBody(
        row: MailRow,
        mailboxes: [String: MailboxRow],
        mailRoot: URL,
        database: OpaquePointer
    ) throws -> String {
        try checkCancellation(.bodyCandidate)
        guard let mailboxID = row.mailboxID, let box = mailboxes[mailboxID] else { return "" }
        guard let url = emlxURL(mailboxURL: box.url, mailRoot: mailRoot, messageROWID: row.id) else { return "" }
        return try parseEmlx(at: url).body
    }

    // MARK: - Models

    private struct MailDetail {
        let id: String
        let messageID: String?
        let subject: String
        let sender: String
        let recipients: String
        let recipientOriginalBytes: Int
        let recipientsTruncated: Bool
        let receivedDate: Date?
        let isRead: Bool?
        let body: String
        var mailbox: String?
        var mailboxRole: String?
    }

    private struct MailRow {
        let id: String
        let messageID: String?
        let subject: String
        let sender: String
        let receivedDate: Date?
        let isRead: Bool?
        let mailboxID: String?
        let senderHaystack: String
    }

    private struct MailStoreFailure: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    // MARK: - Query intent

    private static func parseQueryIntent(_ rawQuery: String) -> (String, Bool, Int?) {
        let lower = StringSanitizer.lower(rawQuery)
        let unreadTerms = ["unread", "ungelesen", "ungelesene", "ungelesener", "unread mail", "unread mails"]
        let unreadOnly = unreadTerms.contains { lower.contains($0) }
        let sinceHours = parseSinceHours(lower)
        let timeTerms = [
            "last 24 hours",
            "last 24h",
            "letzte 24 stunden",
            "letzten 24 stunden",
            "letzte 24h",
            "letzten 24h"
        ]
        let cleanedTerms = unreadTerms + timeTerms
        let cleaned = cleanedTerms.reduce(rawQuery) { value, term in
            value.replacingOccurrences(of: term, with: "", options: [.caseInsensitive, .diacriticInsensitive])
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleaned, unreadOnly, sinceHours)
    }

    private static func parseSinceHours(_ lowerQuery: String) -> Int? {
        if lowerQuery.contains("last 24") || lowerQuery.contains("24h") || lowerQuery.contains("24 stunden") {
            return 24
        }

        if lowerQuery.contains("today") || lowerQuery.contains("heute") {
            return 24
        }

        return nil
    }

    private static func stringList(_ input: [String: JSONValue], _ key: String) -> [String]? {
        switch input[key] {
        case .array(let values):
            let list = values.compactMap { $0.stringValue }
            return list.isEmpty ? nil : list
        case .string(let value):
            let list = value
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return list.isEmpty ? nil : list
        default:
            return nil
        }
    }

    private static func hasBoundedFieldSelector(_ value: JSONValue?) -> Bool {
        switch value {
        case nil:
            return true
        case .string(let string):
            return string.count <= 128
        case .array(let values):
            guard values.count <= SearchRequest.allFields.count else { return false }
            return values.allSatisfy { value in
                guard case .string(let string) = value else { return false }
                return string.count <= 32
            }
        default:
            return false
        }
    }

    private static func hasValidFieldSelector(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        guard case .array(let values) = value, !values.isEmpty else { return false }
        let fields = values.compactMap(\.stringValue).map { StringSanitizer.lower($0) }
        return fields.count == values.count
            && fields.allSatisfy { SearchRequest.allFields.contains($0) }
    }

    // MARK: - Single message

    private func makeDetailResponse(_ detail: MailDetail) throws -> ToolResponse {
        try checkCancellation(.responseItem)
        var metadata: [String: String] = [
            "sender": detail.sender
        ]
        if let messageID = detail.messageID, !messageID.isEmpty {
            metadata["message_id"] = messageID
        }
        if let date = detail.receivedDate {
            metadata["received"] = ISO8601DateFormatter().string(from: date)
        }
        if let isRead = detail.isRead {
            metadata["read"] = String(isRead)
        }
        if !detail.recipients.isEmpty {
            metadata["to"] = detail.recipients
        }
        metadata["recipients_bytes"] = String(detail.recipientOriginalBytes)
        metadata["recipients_returned_bytes"] = String(detail.recipients.utf8.count)
        metadata["recipients_truncated"] = String(detail.recipientsTruncated)
        if let mailbox = detail.mailbox, !mailbox.isEmpty {
            metadata["mailbox"] = mailbox
        }
        if let role = detail.mailboxRole, !role.isEmpty {
            metadata["mailbox_role"] = role
        }

        let item = DataItem(
            id: detail.id,
            title: detail.subject.isEmpty ? "(no subject)" : detail.subject,
            subtitle: detail.sender,
            kind: "mail_message",
            source: sourceName,
            preview: detail.body,
            metadata: metadata
        )
        try checkCancellation(.responseItem)
        let response = ToolResponse(ok: true, source: item.source, items: [item])
        guard let encoded = try? M3JSON.makeEncoder().encode(response),
              encoded.count <= Self.maximumEncodedCollectionResponseBytes else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Mail message metadata exceeded the local transport byte budget."
            )
        }
        return response
    }

    private func readMessageDetail(database: OpaquePointer, rowID: String, mailRoot: URL) throws -> MailDetail {
        try checkCancellation(.requestBoundary)
        let schema = try MailSchema(database: database, provider: self)
        let mailboxes = try readMailboxes(database: database)

        let dateExpr = schema.date.map { "messages.\(Self.quoted($0))" } ?? "NULL"
        let messageIDExpr = schema.messageID.map { "messages.\(Self.quoted($0))" } ?? "NULL"
        let readExpr = schema.read.map { "messages.\(Self.quoted($0))" } ?? "NULL"
        let mailboxExpr = schema.mailbox.map { "messages.\(Self.quoted($0))" } ?? "NULL"

        var sql = """
        SELECT
          messages.ROWID,
          \(messageIDExpr),
          \(schema.subjectExpression),
          \(schema.senderDisplayExpression),
          \(dateExpr),
          \(readExpr),
          \(mailboxExpr)
        FROM messages
        """
        for join in schema.joins { sql += " " + join }
        sql += " WHERE messages.ROWID = ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MailStoreFailure("Could not query Mail index: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, rowID, -1, transientDestructor())

        let stepStatus = try checkedSQLiteStep(statement, database: database, checkpoint: .messageRow)
        guard stepStatus == SQLITE_ROW else {
            throw MailStoreFailure("Message with id \(rowID) not found.")
        }

        let subject = StringSanitizer.compact(
            try textValue(statement, column: 2, field: "messages.subject") ?? "(no subject)",
            limit: 2_000
        )
        let sender = StringSanitizer.compact(
            try textValue(statement, column: 3, field: "messages.sender") ?? "",
            limit: 2_000
        )
        let date = dateValue(statement, column: 4)
        let isRead = boolValue(statement, column: 5)
        let mailboxID = try textValue(statement, column: 6, field: "messages.mailbox")

        var body = ""
        var recipients = ""

        if let mailboxID, let box = mailboxes[mailboxID],
           let emlxURL = emlxURL(mailboxURL: box.url, mailRoot: mailRoot, messageROWID: rowID) {
            let parsed = try parseEmlx(at: emlxURL)
            body = parsed.body
            recipients = parsed.to
        }

        if body.isEmpty, let found = try findEmlxBySearch(mailRoot: mailRoot, messageROWID: rowID) {
            let parsed = try parseEmlx(at: found)
            body = parsed.body
            if recipients.isEmpty { recipients = parsed.to }
        }

        if recipients.isEmpty {
            recipients = (try readRecipients(database: database, schema: schema, messageIDs: [rowID]))[rowID] ?? ""
        }

        try checkCancellation(.bodyParsing)
        let boundedRecipients = ProviderOutputBudget.text(
            recipients,
            maximumUTF8Bytes: Self.maximumReturnedRecipientUTF8Bytes
        )

        let box = mailboxID.flatMap { mailboxes[$0] }
        return MailDetail(
            id: rowID,
            messageID: try textValue(statement, column: 1, field: "messages.message_id")
                .map { String($0.prefix(2_000)) },
            subject: subject,
            sender: sender,
            recipients: boundedRecipients.text,
            recipientOriginalBytes: boundedRecipients.originalBytes,
            recipientsTruncated: boundedRecipients.truncated,
            receivedDate: date,
            isRead: isRead,
            body: body.isEmpty ? "(body not available — .emlx file not found)" : body,
            mailbox: box.map { $0.path.isEmpty ? $0.name : $0.path },
            mailboxRole: box?.role
        )
    }

    private func emlxURL(mailboxURL raw: String, mailRoot: URL, messageROWID: String) -> URL? {
        let mailboxPath: URL
        if raw.hasPrefix("file://") {
            guard let parsed = URL(string: raw) else { return nil }
            mailboxPath = parsed
        } else if raw.hasPrefix("/") {
            mailboxPath = URL(fileURLWithPath: raw)
        } else if let parsed = URL(string: raw), let scheme = parsed.scheme, !scheme.isEmpty {
            // A remote mailbox url is not a filesystem path; the cached files live under the store.
            _ = parsed
            return nil
        } else {
            mailboxPath = mailRoot.appendingPathComponent(raw, isDirectory: true)
        }

        let resolvedMailbox = mailboxPath.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(resolvedMailbox, of: mailRoot) else { return nil }

        let candidates = [
            resolvedMailbox.appendingPathComponent("Messages/\(messageROWID).emlx"),
            resolvedMailbox.appendingPathComponent("Messages/\(messageROWID).partial.emlx"),
            resolvedMailbox.appendingPathComponent("\(messageROWID).emlx")
        ]
        return candidates.compactMap { safeRegularFile($0, under: mailRoot) }.first
    }

    private func findEmlxBySearch(mailRoot: URL, messageROWID: String) throws -> URL? {
        try checkCancellation(.emlxSearchEntry)
        let enumerator = fileManager.enumerator(
            at: mailRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        let targetNames = Set(["\(messageROWID).emlx", "\(messageROWID).partial.emlx"])
        var inspected = 0
        while let url = enumerator?.nextObject() as? URL {
            try checkCancellation(.emlxSearchEntry)
            inspected += 1
            guard inspected <= Self.maximumEmlxSearchEntries else { return nil }
            if targetNames.contains(url.lastPathComponent),
               let safe = safeRegularFile(url, under: mailRoot) {
                return safe
            }
        }
        return nil
    }

    private func safeRegularFile(_ url: URL, under root: URL) -> URL? {
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return isDescendant(resolved, of: root) ? resolved : nil
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    // MARK: - Store location

    private func locateEnvelopeIndex() throws -> URL {
        try checkCancellation(.requestBoundary)
        let override = ProcessInfo.processInfo.environment[Self.mailRootEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mailRoot = (override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mail", isDirectory: true)

        guard fileManager.fileExists(atPath: mailRoot.path) else {
            throw MailStoreFailure("Local Mail store was not found at \(mailRoot.path).")
        }

        let versions: [URL]
        do {
            versions = try fileManager.contentsOfDirectory(
                at: mailRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw MailStoreFailure("Cannot inspect the local Mail store at \(mailRoot.path). Grant Full Disk Access to M3MCP, then restart the app. Detail: \(error.localizedDescription)")
        }
        try checkCancellation(.requestBoundary)

        var versionDirectories: [URL] = []
        versionDirectories.reserveCapacity(versions.count)
        for url in versions {
            try checkCancellation(.requestBoundary)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               url.lastPathComponent.hasPrefix("V") {
                versionDirectories.append(url)
            }
        }
        versionDirectories.sort { lhs, rhs in
            versionNumber(lhs.lastPathComponent) > versionNumber(rhs.lastPathComponent)
        }
        try checkCancellation(.requestBoundary)

        var index: URL?
        for version in versionDirectories {
            try checkCancellation(.requestBoundary)
            let candidate = version.appendingPathComponent("MailData/Envelope Index", isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                index = candidate
                break
            }
        }

        guard let index else {
            throw MailStoreFailure("Mail Envelope Index was not found below \(mailRoot.path).")
        }

        return index
    }

    private func versionNumber(_ name: String) -> Int {
        Int(name.dropFirst()) ?? 0
    }

    // MARK: - .emlx parsing

    private func parseEmlx(at url: URL) throws -> (body: String, to: String) {
        try checkCancellation(.bodyParsing)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ("", "")
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: Self.maximumEmlxBytes + 1) ?? Data()
        } catch {
            return ("", "")
        }
        try checkCancellation(.bodyParsing)

        let sourceWasTruncated = data.count > Self.maximumEmlxBytes
        let bounded = data.prefix(Self.maximumEmlxBytes)
        let content = String(decoding: bounded, as: UTF8.self)
        try checkCancellation(.bodyParsing)

        guard let firstNewline = content.firstIndex(of: "\n") else {
            return ("", "")
        }

        let emailStart = content.index(after: firstNewline)
        let emailPart: String
        if let plistMarker = content.range(of: "<?xml ", options: [], range: emailStart..<content.endIndex) {
            emailPart = String(content[emailStart..<plistMarker.lowerBound])
        } else {
            emailPart = String(content[emailStart...])
        }

        let to = try extractHeader(emailPart, name: "To")
        let body = try extractBody(emailPart, depth: 0)
        var truncated = body.count > 8_000 ? String(body.prefix(8_000)) + "\n[truncated]" : body
        if sourceWasTruncated {
            truncated += truncated.isEmpty
                ? "[message exceeds the safe read limit]"
                : "\n[source truncated at \(Self.maximumEmlxBytes) bytes]"
        }
        return (truncated, to)
    }

    private func extractHeader(_ email: String, name: String) throws -> String {
        try checkCancellation(.bodyParsing)
        let headerEnd = email.range(of: "\r\n\r\n") ?? email.range(of: "\n\n")
        let headerSection = headerEnd.map { String(email[email.startIndex..<$0.lowerBound]) } ?? email

        let pattern = "(?mi)^\(NSRegularExpression.escapedPattern(for: name)):\\s*(.+?)(?=\\n\\S|\\n\\n|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: headerSection, range: NSRange(headerSection.startIndex..., in: headerSection)),
              let range = Range(match.range(at: 1), in: headerSection) else {
            return ""
        }

        try checkCancellation(.bodyParsing)
        return headerSection[range]
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func extractBody(_ email: String, depth: Int) throws -> String {
        try checkCancellation(.bodyParsing)
        guard depth <= Self.maximumMultipartDepth else {
            return "[multipart nesting limit reached]"
        }

        let separator = email.contains("\r\n\r\n") ? "\r\n\r\n" : "\n\n"
        guard let bodyRange = email.range(of: separator) else {
            return ""
        }

        let rawBody = String(email[bodyRange.upperBound...])

        let contentType = try extractHeader(email, name: "Content-Type").lowercased()
        let transferEncoding = try extractHeader(email, name: "Content-Transfer-Encoding").lowercased()

        var decoded = rawBody
        if transferEncoding.contains("quoted-printable") {
            decoded = try Self.decodeQuotedPrintableTextCancellable(
                rawBody,
                contentType: contentType,
                maximumOutputBytes: Self.maximumDecodedBodyBytes,
                cancellationCheck: { [cancellationCheck] in cancellationCheck(.bodyParsing) }
            )
        } else if transferEncoding.contains("base64") {
            try checkCancellation(.bodyParsing)
            if let data = Data(base64Encoded: decoded.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: ""), options: .ignoreUnknownCharacters),
               let text = String(data: data, encoding: .utf8) {
                decoded = text
            }
            try checkCancellation(.bodyParsing)
        }

        if contentType.contains("text/html") {
            decoded = try stripHTML(decoded)
        }

        if contentType.contains("multipart/") {
            decoded = try extractMultipartText(rawBody, contentType: contentType, depth: depth + 1)
        }

        try checkCancellation(.bodyParsing)
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractMultipartText(_ body: String, contentType: String, depth: Int) throws -> String {
        try checkCancellation(.bodyParsing)
        let boundaryPattern = "boundary=\"?([^\";\\s]+)\"?"
        guard let regex = try? NSRegularExpression(pattern: boundaryPattern),
              let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
              let range = Range(match.range(at: 1), in: contentType) else {
            return body
        }

        let boundaryValue = String(contentType[range])
        guard (1...200).contains(boundaryValue.utf8.count) else { return body }
        let boundary = "--" + boundaryValue
        let parts = try Self.boundedComponentsCancellable(
            of: body,
            separatedBy: boundary,
            limit: Self.maximumMultipartParts,
            cancellationCheck: { [cancellationCheck] in cancellationCheck(.bodyParsing) }
        )

        var plainText = ""
        var htmlText = ""

        for part in parts {
            try checkCancellation(.bodyParsing)
            let lower = part.lowercased()
            if lower.contains("content-type: text/plain") || lower.contains("content-type:text/plain") {
                let partBody = try extractBody(String(part), depth: depth)
                if !partBody.isEmpty { plainText = partBody }
            } else if lower.contains("content-type: text/html") || lower.contains("content-type:text/html") {
                let partBody = try extractBody(String(part), depth: depth)
                if !partBody.isEmpty { htmlText = try stripHTML(partBody) }
            }
        }

        return plainText.isEmpty ? htmlText : plainText
    }

    /// Equivalent to `components(separatedBy:).prefix(limit)` without first materializing every
    /// attacker-controlled component. Returned substrings share the bounded source storage.
    static func boundedComponents(
        of body: String,
        separatedBy separator: String,
        limit: Int
    ) -> [Substring] {
        (try? boundedComponentsCancellable(
            of: body,
            separatedBy: separator,
            limit: limit,
            cancellationCheck: { false }
        )) ?? []
    }

    private static func boundedComponentsCancellable(
        of body: String,
        separatedBy separator: String,
        limit: Int,
        cancellationCheck: () -> Bool
    ) throws -> [Substring] {
        guard !separator.isEmpty, limit > 0 else { return [] }
        var parts: [Substring] = []
        parts.reserveCapacity(min(limit, 128))
        var start = body.startIndex

        while parts.count < limit {
            if cancellationCheck() { throw CancellationError() }
            guard let boundary = body.range(of: separator, range: start..<body.endIndex) else {
                parts.append(body[start..<body.endIndex])
                break
            }
            parts.append(body[start..<boundary.lowerBound])
            start = boundary.upperBound
        }
        return parts
    }

    private func stripHTML(_ html: String) throws -> String {
        var text = html
        try checkCancellation(.bodyParsing)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        try checkCancellation(.bodyParsing)
        text = text.replacingOccurrences(of: "<p[^>]*>", with: "\n", options: .regularExpression)
        try checkCancellation(.bodyParsing)
        text = text.replacingOccurrences(of: "</p>", with: "\n")
        try checkCancellation(.bodyParsing)
        text = text.replacingOccurrences(of: "<div[^>]*>", with: "\n", options: .regularExpression)
        try checkCancellation(.bodyParsing)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        try checkCancellation(.bodyParsing)
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        try checkCancellation(.bodyParsing)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        try checkCancellation(.bodyParsing)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        try checkCancellation(.bodyParsing)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeQuotedPrintableBytes(_ input: String, maximumOutputBytes: Int) -> Data {
        (try? decodeQuotedPrintableBytesCancellable(
            input,
            maximumOutputBytes: maximumOutputBytes,
            cancellationCheck: { false }
        )) ?? Data()
    }

    private static func decodeQuotedPrintableBytesCancellable(
        _ input: String,
        maximumOutputBytes: Int,
        cancellationCheck: () -> Bool
    ) throws -> Data {
        guard maximumOutputBytes > 0 else { return Data() }

        let equals = UInt8(ascii: "=")
        let carriageReturn = UInt8(ascii: "\r")
        let lineFeed = UInt8(ascii: "\n")
        let bytes = input.utf8
        var output = Data()
        var index = bytes.startIndex
        var iterations = 0

        while index != bytes.endIndex, output.count < maximumOutputBytes {
            if iterations & 0xFFF == 0, cancellationCheck() {
                throw CancellationError()
            }
            iterations += 1
            let byte = bytes[index]
            guard byte == equals else {
                output.append(byte)
                index = bytes.index(after: index)
                continue
            }

            let firstIndex = bytes.index(after: index)
            guard firstIndex != bytes.endIndex else {
                output.append(equals)
                break
            }

            let first = bytes[firstIndex]
            if first == lineFeed {
                index = bytes.index(after: firstIndex)
                continue
            }

            let secondIndex = bytes.index(after: firstIndex)
            if first == carriageReturn,
               secondIndex != bytes.endIndex,
               bytes[secondIndex] == lineFeed {
                index = bytes.index(after: secondIndex)
                continue
            }

            if secondIndex != bytes.endIndex,
               let high = quotedPrintableHexNibble(first),
               let low = quotedPrintableHexNibble(bytes[secondIndex]) {
                output.append((high << 4) | low)
                index = bytes.index(after: secondIndex)
                continue
            }

            // A malformed escape is literal. Advancing only past '=' lets the following bytes be
            // considered normally (including a second '=' that may begin a valid escape).
            output.append(equals)
            index = firstIndex
        }

        return output
    }

    static func decodeQuotedPrintableText(
        _ input: String,
        contentType: String,
        maximumOutputBytes: Int
    ) -> String {
        (try? decodeQuotedPrintableTextCancellable(
            input,
            contentType: contentType,
            maximumOutputBytes: maximumOutputBytes,
            cancellationCheck: { false }
        )) ?? ""
    }

    private static func decodeQuotedPrintableTextCancellable(
        _ input: String,
        contentType: String,
        maximumOutputBytes: Int,
        cancellationCheck: () -> Bool
    ) throws -> String {
        let data = try decodeQuotedPrintableBytesCancellable(
            input,
            maximumOutputBytes: maximumOutputBytes,
            cancellationCheck: cancellationCheck
        )
        if cancellationCheck() { throw CancellationError() }
        let encoding = stringEncoding(for: declaredCharset(in: contentType)) ?? .utf8

        if let text = String(data: data, encoding: encoding) {
            return text
        }
        if encoding != .utf8, let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func quotedPrintableHexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        default:
            return nil
        }
    }

    private static func declaredCharset(in contentType: String) -> String? {
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "charset" else {
                continue
            }
            return pair[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func stringEncoding(for charset: String?) -> String.Encoding? {
        guard let charset else { return nil }
        switch charset.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "utf-8", "utf8":
            return .utf8
        case "us-ascii", "ascii":
            return .ascii
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "utf-16":
            return .utf16
        case "utf-16le":
            return .utf16LittleEndian
        case "utf-16be":
            return .utf16BigEndian
        default:
            return nil
        }
    }

    // MARK: - SQLite plumbing

    private final class SQLiteRecipientWorkContext {
        let isCancelled: () -> Bool
        private var remainingCallbacks: Int
        private(set) var cancellationObserved = false
        private(set) var workBudgetExceeded = false

        init(
            maximumInstructions: Int,
            instructionStride: Int32,
            isCancelled: @escaping () -> Bool
        ) {
            self.isCancelled = isCancelled
            remainingCallbacks = max(1, maximumInstructions / Int(instructionStride))
        }

        func progress() -> Int32 {
            if isCancelled() {
                cancellationObserved = true
                return 1
            }
            remainingCallbacks -= 1
            if remainingCallbacks <= 0 {
                workBudgetExceeded = true
                return 1
            }
            return 0
        }
    }

    private func installCancellationProgressHandler(on database: OpaquePointer) {
        sqlite3_progress_handler(
            database,
            Self.sqliteProgressInstructionStride,
            { rawProvider -> Int32 in
                guard let rawProvider else { return 0 }
                let provider = Unmanaged<MailProvider>
                    .fromOpaque(rawProvider)
                    .takeUnretainedValue()
                return provider.cancellationCheck(.sqliteProgress) ? 1 : 0
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func recipientWorkBudgetFailure() -> MailStoreFailure {
        MailStoreFailure(
            "Mail recipient lookup exceeded its hard work safety budget of \(Self.maximumRecipientJoinVMInstructions) SQLite instructions. Narrow the search, reduce limit/max_candidates, or omit recipients."
        )
    }

    /// Read-only, always. Nothing in this provider is allowed to change the user's mail.
    private func withDatabase<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        try checkCancellation(.databaseWork)
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)

        guard status == SQLITE_OK, let database else {
            let message = database.map(databaseMessage) ?? "OSStatus \(status)"
            if let database {
                sqlite3_close(database)
            }
            throw MailStoreFailure("Cannot read the local Mail index. Grant Full Disk Access to M3MCP, then restart the app. Detail: \(message)")
        }

        defer { sqlite3_close(database) }
        MailSQLiteValuePolicy.applyConnectionLimit(to: database)
        sqlite3_busy_timeout(database, 800)

        // Row-level gates cannot stop one expensive SQLite virtual-machine step (for example a
        // filtered count over a large Envelope Index). SQLite's progress callback runs on the same
        // execution path and turns client cancellation into SQLITE_INTERRUPT within a bounded
        // number of VM instructions.
        installCancellationProgressHandler(on: database)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }

        let result = try body(database)
        try checkCancellation(.databaseWork)
        return result
    }

    private func tableColumns(database: OpaquePointer, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MailStoreFailure("Could not inspect Mail index schema: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while true {
            let status = try checkedSQLiteStep(statement, database: database, checkpoint: .databaseWork)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw MailStoreFailure("Could not inspect Mail index schema: \(databaseMessage(database))")
            }
            if let name = try textValue(statement, column: 1, field: "schema.column_name") {
                columns.insert(name)
            }
        }
        return columns
    }

    private func checkedSQLiteStep(
        _ statement: OpaquePointer,
        database: OpaquePointer,
        checkpoint: CancellationCheckpoint
    ) throws -> Int32 {
        try checkCancellation(checkpoint)
        let status = sqlite3_step(statement)
        if status == SQLITE_INTERRUPT || cancellationCheck(checkpoint) {
            throw CancellationError()
        }
        return status
    }

    private func pick(_ columns: Set<String>, _ names: [String]) -> String? {
        for name in names where columns.contains(name) {
            return name
        }
        return nil
    }

    private static func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    @discardableResult
    private func bind(_ values: [String], to statement: OpaquePointer, from start: Int32) throws -> Int32 {
        var index = start
        for value in values {
            try checkCancellation(.databaseWork)
            sqlite3_bind_text(statement, index, value, -1, transientDestructor())
            index += 1
        }
        return index
    }

    private func textValue(
        _ statement: OpaquePointer,
        column: Int32,
        field: String
    ) throws -> String? {
        try MailSQLiteValuePolicy.text(statement, column: column, field: field)
    }

    private func boolValue(_ statement: OpaquePointer, column: Int32) -> Bool? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int(statement, column) != 0
    }

    private func intValue(_ statement: OpaquePointer, column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, column))
    }

    private func dateValue(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }

        let value = sqlite3_column_double(statement, column)
        if !value.isFinite || value <= 0 {
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
