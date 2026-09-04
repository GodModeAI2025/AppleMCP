import Foundation
import M3MCPCore
import SQLite3

/// Read-only access to the local Apple Mail store.
///
/// Mail keeps an SQLite index (`Envelope Index`) beside the `.emlx` files, so this provider reads the
/// index directly instead of driving Mail.app through AppleEvents. Every connection is opened
/// `SQLITE_OPEN_READONLY`, and no code path here sends, files, deletes or marks anything.
final class MailProvider {
    private let fileManager = FileManager.default
    private let sourceName = "Mail Local Index"

    /// Relocates the Mail store root the provider reads, so a synthetic index can stand in for the
    /// real one. Reading `~/Library/Mail` needs Full Disk Access, and a TCC grant follows the
    /// *responsible process*, so a build started from a terminal inherits that terminal's grants —
    /// which makes a development build unable to read real mail even on the machine that owns it.
    /// Without this seam the search behaviour cannot be tested at all.
    ///
    /// Same shape as `M3MCP_SOCKET_DIR`, and read-only like everything else here.
    static let mailRootEnvironmentKey = "M3MCP_MAIL_ROOT"

    // MARK: - Tools

    func search(input: [String: JSONValue]) async -> ToolResponse {
        let request = SearchRequest(input: input)

        do {
            let indexURL = try locateEnvelopeIndex()
            let mailRoot = indexURL.deletingLastPathComponent().deletingLastPathComponent()
            return try withDatabase(at: indexURL) { database in
                try runSearch(request, database: database, mailRoot: mailRoot)
            }
        } catch {
            return await appleScriptSearch(request: request)
        }
    }

    func listMailboxes(input: [String: JSONValue]) async -> ToolResponse {
        let query = StringSanitizer.lower(input.string("query"))
        let role = StringSanitizer.lower(input.string("role"))

        do {
            let indexURL = try locateEnvelopeIndex()
            let boxes = try withDatabase(at: indexURL) { database in
                try readMailboxes(database: database)
            }

            let filtered = boxes.values
                .filter { box in
                    if !role.isEmpty, box.role != role { return false }
                    guard !query.isEmpty else { return true }
                    return StringSanitizer.lower(box.path).contains(query)
                        || StringSanitizer.lower(box.name).contains(query)
                        || StringSanitizer.lower(box.account).contains(query)
                }
                .sorted { lhs, rhs in
                    if lhs.account != rhs.account { return lhs.account < rhs.account }
                    return lhs.path.localizedLowercase < rhs.path.localizedLowercase
                }

            let items = filtered.map { box in
                DataItem(
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
                )
            }

            return ToolResponse(
                ok: true,
                source: sourceName,
                items: items,
                message: items.isEmpty ? "No mailboxes matched." : nil,
                meta: [
                    "returned": String(items.count),
                    "total": String(boxes.count),
                    "has_more": "false",
                    "truncated": "false",
                    "role_filter": role,
                    "query": query
                ]
            )
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
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: "Mail", message: "Missing required argument: id")
        }

        if id.hasPrefix("as:") {
            let messageID = String(id.dropFirst(3))
            return await appleScriptRead(messageID: messageID)
        }

        do {
            let indexURL = try locateEnvelopeIndex()
            let mailRoot = indexURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()

            let detail = try withDatabase(at: indexURL) { database -> MailDetail in
                try readMessageDetail(database: database, rowID: id, mailRoot: mailRoot)
            }

            return makeDetailResponse(detail)
        } catch {
            return await appleScriptRead(messageID: id)
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

            // body is in the default. It was not, which meant a plain mail_search("Rechnung") never
            // opened a single message and said nothing about it: the caller had to know that body
            // was opt-in to get a full-text search at all.
            let asked = MailProvider.stringList(input, "fields") ?? SearchRequest.allFields
            let normalised = asked
                .map { StringSanitizer.lower($0) }
                .filter { SearchRequest.allFields.contains($0) }
            fields = normalised.isEmpty ? SearchRequest.allFields : normalised

            // 500, not 50. The old ceiling was low enough that a week of mail did not fit in one
            // response, and nothing said so.
            limit = max(1, min(input.int("limit", default: 25), 500))
            offset = max(0, input.int("offset", default: 0))
            unreadOnly = input.bool("unread_only", default: autoIntent ? intent.1 : false)
            sinceHours = max(0, input.int("since_hours", default: (autoIntent ? intent.2 : nil) ?? 0))
            includeJunk = input.bool("include_junk", default: false)
            mailboxFilter = input.string("mailbox").trimmingCharacters(in: .whitespacesAndNewlines)
            includeBody = input.bool("include_body", default: false)
            includeRecipients = input.bool("include_recipients", default: false)
            maxCandidates = max(limit + offset, min(input.int("max_candidates", default: 500), 5_000))
        }

        var searchesBody: Bool { fields.contains("body") && !terms.isEmpty }

        /// Whether any field is one SQL can match on. When none is, the candidate set is the scan
        /// window alone and the second query would only repeat the first.
        var searchesIndexedFields: Bool {
            fields.contains { $0 == "subject" || $0 == "sender" || $0 == "recipients" }
        }
    }

    // MARK: - Search

    private func runSearch(
        _ request: SearchRequest,
        database: OpaquePointer,
        mailRoot: URL
    ) throws -> ToolResponse {
        let schema = try MailSchema(database: database, provider: self)
        let mailboxes = try readMailboxes(database: database)

        var selected: Set<String>?
        var mailboxFilterMatched = 0
        if !request.mailboxFilter.isEmpty {
            let matches = matchMailboxes(request.mailboxFilter, in: mailboxes)
            mailboxFilterMatched = matches.count
            selected = Set(matches.map { $0.id })
            if matches.isEmpty {
                return ToolResponse(
                    ok: true,
                    source: sourceName,
                    items: [],
                    message: "No mailbox matches '\(request.mailboxFilter)'. Call mail_list_mailboxes to see the names.",
                    meta: baseMeta(request, schema: schema, mailboxes: mailboxes, total: 0, returned: 0,
                                  totalExact: true, hasMore: false, scanned: 0, scanCapped: false,
                                  indexCapped: false, mailboxFilterMatched: 0)
                )
            }
        }

        let clause = try buildWhere(request, schema: schema, mailboxIDs: selected)

        // Body matching cannot be expressed in SQL — the text is in the .emlx files — so a body search
        // reads candidate messages and filters them here. Which rows become candidates is the whole
        // question, and getting it wrong was silent.
        //
        // It used to be "the rows the SQL term clause matched". With fields = [subject, body] that
        // clause only matches subjects, so a message carrying the word solely in its body never became
        // a candidate, was never read, and the reply still said total_exact: true. A miss that reports
        // itself as a complete answer is worse than a miss.
        //
        // The candidate set is now the union of two queries:
        //   * every row the term clause matches on the indexed fields;
        //   * the newest `max_candidates` rows in scope regardless of terms, which is the window the
        //     body is actually read from.
        // Both are fetched with `limit: max_candidates`, so both can be cut short. That is the price
        // of this path and it is reported rather than hidden: `meta.index_capped` and
        // `meta.body_scan_capped` say which side hit the bound, `meta.total_exact` turns false, and
        // `offset` pages inside the candidate set rather than over the whole index. A caller that
        // needs an exact total and SQL paging leaves `body` out of `fields` and takes the branch
        // below, which counts and pages in SQL.
        if request.searchesBody {
            let scanClause = try buildWhere(
                request, schema: schema, mailboxIDs: selected, includeTermPredicates: false
            )

            let indexMatches: [MailRow]
            if request.searchesIndexedFields, clause.sql != scanClause.sql {
                indexMatches = try fetchRows(
                    request, schema: schema, clause: clause, database: database,
                    limit: request.maxCandidates, offset: 0
                )
            } else {
                indexMatches = []
            }

            let scanWindow = try fetchRows(
                request, schema: schema, clause: scanClause, database: database,
                limit: request.maxCandidates, offset: 0
            )
            let bodyScanCapped = scanWindow.count >= request.maxCandidates
            let indexCapped = indexMatches.count >= request.maxCandidates
            let scanCapped = bodyScanCapped || indexCapped

            var seen = Set<String>()
            var candidates: [MailRow] = []
            for row in indexMatches + scanWindow where seen.insert(row.id).inserted {
                candidates.append(row)
            }
            candidates.sort { lhs, rhs in
                let left = lhs.receivedDate ?? .distantPast
                let right = rhs.receivedDate ?? .distantPast
                if left != right { return left > right }
                return (Int(lhs.id) ?? 0) > (Int(rhs.id) ?? 0)
            }

            let recipientText = request.fields.contains("recipients") || request.includeRecipients
                ? try readRecipients(database: database, schema: schema, messageIDs: candidates.map { $0.id })
                : [:]

            var matched: [MailRow] = []
            var bodies: [String: String] = [:]
            for row in candidates {
                let body = loadBody(row: row, mailboxes: mailboxes, mailRoot: mailRoot, database: database)
                let hits = fieldsMatched(
                    request, row: row, recipients: recipientText[row.id] ?? "", body: body
                )
                guard !hits.isEmpty else { continue }
                matched.append(row)
                if request.includeBody { bodies[row.id] = body }
            }

            let page = Array(matched.dropFirst(request.offset).prefix(request.limit))
            let hasMore = matched.count > request.offset + page.count
            let items = page.map { row in
                makeItem(
                    row,
                    mailboxes: mailboxes,
                    fieldsMatched: fieldsMatched(request, row: row, recipients: recipientText[row.id] ?? "",
                                                 body: bodies[row.id] ?? ""),
                    recipients: request.includeRecipients ? recipientText[row.id] : nil,
                    bodySnippet: request.includeBody ? bodies[row.id] : nil
                )
            }

            return ToolResponse(
                ok: true,
                source: sourceName,
                items: items,
                message: message(items: items, hasMore: hasMore, bodyScanCapped: bodyScanCapped,
                                 indexCapped: indexCapped, request: request),
                meta: baseMeta(request, schema: schema, mailboxes: mailboxes, total: matched.count,
                               returned: items.count, totalExact: !scanCapped, hasMore: hasMore,
                               scanned: candidates.count, scanCapped: scanCapped,
                               indexCapped: indexCapped,
                               mailboxFilterMatched: mailboxFilterMatched,
                               bodyScan: BodyScan(
                                   performed: true,
                                   limit: request.maxCandidates,
                                   capped: bodyScanCapped,
                                   messagesRead: candidates.count
                               ))
            )
        }

        let total = try countRows(schema: schema, clause: clause, database: database)
        let rows = try fetchRows(
            request, schema: schema, clause: clause, database: database,
            limit: request.limit, offset: request.offset
        )
        let recipientText = request.fields.contains("recipients") || request.includeRecipients
            ? try readRecipients(database: database, schema: schema, messageIDs: rows.map { $0.id })
            : [:]

        let items = rows.map { row -> DataItem in
            var body = ""
            if request.includeBody {
                body = loadBody(row: row, mailboxes: mailboxes, mailRoot: mailRoot, database: database)
            }
            return makeItem(
                row,
                mailboxes: mailboxes,
                fieldsMatched: fieldsMatched(request, row: row, recipients: recipientText[row.id] ?? "", body: body),
                recipients: request.includeRecipients ? recipientText[row.id] : nil,
                bodySnippet: request.includeBody ? body : nil
            )
        }

        let hasMore = total > request.offset + items.count
        return ToolResponse(
            ok: true,
            source: sourceName,
            items: items,
            message: message(items: items, hasMore: hasMore, bodyScanCapped: false,
                             indexCapped: false, request: request),
            meta: baseMeta(request, schema: schema, mailboxes: mailboxes, total: total, returned: items.count,
                           totalExact: true, hasMore: hasMore, scanned: total, scanCapped: false,
                           indexCapped: false,
                           mailboxFilterMatched: mailboxFilterMatched)
        )
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
        indexCapped: Bool,
        mailboxFilterMatched: Int,
        bodyScan: BodyScan = .notPerformed
    ) -> [String: String] {
        [
            "returned": String(returned),
            "offset": String(request.offset),
            "limit": String(request.limit),
            "total": String(total),
            "total_exact": String(totalExact),
            "has_more": String(hasMore),
            "truncated": String(hasMore || scanCapped),
            "scanned": String(scanned),
            "scan_capped": String(scanCapped),
            // Which side of the candidate set hit max_candidates. The index side is bounded too when
            // body is searched, and saying only "body_scan_capped" would blame the wrong half.
            "index_capped": String(indexCapped),
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
            // Was hardcoded "true", which said nothing: it was true whether or not a body had been
            // opened. These four report what actually happened.
            "body_searched": String(bodyScan.performed),
            "body_scan_limit": String(bodyScan.limit),
            "body_scan_capped": String(bodyScan.capped),
            "body_messages_read": String(bodyScan.messagesRead)
        ]
    }

    /// What a body search did, for `meta`. A body search is bounded by `max_candidates`; when the
    /// window is full there are older messages nobody looked inside, and the caller has to be told.
    private struct BodyScan {
        let performed: Bool
        let limit: Int
        let capped: Bool
        let messagesRead: Int

        static let notPerformed = BodyScan(performed: false, limit: 0, capped: false, messagesRead: 0)
    }

    private func message(
        items: [DataItem],
        hasMore: Bool,
        bodyScanCapped: Bool,
        indexCapped: Bool,
        request: SearchRequest
    ) -> String? {
        if items.isEmpty {
            if request.offset > 0 {
                return "No messages at offset \(request.offset). Lower offset, or read meta.total. With body among the fields, offset pages inside the candidate set only, and that set holds at most max_candidates=\(request.maxCandidates) messages."
            }
            return "No matching messages found in the local Mail index."
        }
        // Two different caps, and blaming the body scan for both is how a truncated index answer
        // came back looking like a complete one.
        if indexCapped && bodyScanCapped {
            return "Capped at max_candidates=\(request.maxCandidates) on both sides: that many index hits and that many messages opened for the body, so meta.total is a lower bound and offset pages only inside that set. Raise max_candidates, narrow with mailbox or since_hours, or drop body from fields for an exact total with SQL paging."
        }
        if indexCapped {
            return "Subject, sender and recipient hits were cut at max_candidates=\(request.maxCandidates); there are more in the index. meta.total is a lower bound and offset pages only inside the candidate set. Raise max_candidates, or drop body from fields for an exact total with SQL paging."
        }
        if bodyScanCapped {
            return "Body search read the newest \(request.maxCandidates) messages in scope; older ones were not opened, so meta.total is a lower bound and meta.body_scan_capped is true. Raise max_candidates, or narrow the search with mailbox or since_hours."
        }
        if hasMore {
            return "meta.has_more is true: this is not the whole result set. Page with offset."
        }
        return nil
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

    /// `includeTermPredicates: false` drops the search terms and keeps only the scope filters —
    /// deleted, junk, unread, time window, mailbox. That is the window a body search reads from: the
    /// terms cannot be applied in SQL for the body, so applying them to the candidates is what threw
    /// body-only matches away.
    private func buildWhere(
        _ request: SearchRequest,
        schema: MailSchema,
        mailboxIDs: Set<String>?,
        includeTermPredicates: Bool = true
    ) throws -> WhereClause {
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
            let list = mailboxIDs.sorted().map { _ in "?" }.joined(separator: ",")
            predicates.append("messages.\(Self.quoted(mailbox)) IN (\(list))")
            bindings.append(contentsOf: mailboxIDs.sorted())
        }

        // One clause per term, ORed across the requested fields and ANDed across the terms — so
        // "Graph API" means both words somewhere in the scoped fields rather than that exact string,
        // which returned nothing.
        if includeTermPredicates, !request.terms.isEmpty {
            var termClauses: [String] = []
            for term in request.terms {
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
            } else if !request.searchesBody {
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

        bind(clause.bindings, to: statement, from: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
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

        var index = bind(clause.bindings, to: statement, from: 1)
        sqlite3_bind_int(statement, index, Int32(limit)); index += 1
        sqlite3_bind_int(statement, index, Int32(offset))

        var rows: [MailRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                MailRow(
                    id: textValue(statement, column: 0) ?? UUID().uuidString,
                    messageID: textValue(statement, column: 1),
                    subject: textValue(statement, column: 2) ?? "(no subject)",
                    sender: textValue(statement, column: 3) ?? "",
                    receivedDate: dateValue(statement, column: 4),
                    isRead: boolValue(statement, column: 5),
                    mailboxID: textValue(statement, column: 6),
                    senderHaystack: textValue(statement, column: 7) ?? ""
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
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }
        bind(messageIDs, to: statement, from: 1)

        var out: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = textValue(statement, column: 0) else { continue }
            let value = (textValue(statement, column: 1) ?? "").trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            out[key] = out[key].map { "\($0), \(value)" } ?? value
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
    ) -> [String] {
        guard !request.terms.isEmpty else { return [] }

        let haystacks: [(String, String)] = [
            ("subject", StringSanitizer.lower(row.subject)),
            ("sender", StringSanitizer.lower(row.senderHaystack.isEmpty ? row.sender : row.senderHaystack)),
            ("recipients", StringSanitizer.lower(recipients)),
            ("body", StringSanitizer.lower(body))
        ]
        let lowered = request.terms.map { StringSanitizer.lower($0) }

        var hits: [String] = []
        for (name, haystack) in haystacks where request.fields.contains(name) {
            let matched: Bool
            switch request.match {
            case "any", "phrase":
                matched = lowered.contains { !$0.isEmpty && haystack.contains($0) }
            default:
                matched = lowered.allSatisfy { !$0.isEmpty && haystack.contains($0) }
            }
            if matched { hits.append(name) }
        }
        return hits
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

    private func readMailboxes(database: OpaquePointer) throws -> [String: MailboxRow] {
        let columns = try tableColumns(database: database, table: "mailboxes")
        guard let urlColumn = pick(columns, ["url"]) else { return [:] }

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
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var out: [String: MailboxRow] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = textValue(statement, column: 0) else { continue }
            let raw = textValue(statement, column: 1) ?? ""
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
        return out
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
    private func matchMailboxes(_ filter: String, in boxes: [String: MailboxRow]) -> [MailboxRow] {
        let needle = StringSanitizer.lower(filter)
        let all = Array(boxes.values)

        if let exactID = boxes[filter] { return [exactID] }

        let exactPath = all.filter { StringSanitizer.lower($0.path) == needle }
        if !exactPath.isEmpty { return exactPath }

        let exactName = all.filter { StringSanitizer.lower($0.name) == needle }
        if !exactName.isEmpty { return exactName }

        let byRole = all.filter { $0.role == needle }
        if !byRole.isEmpty { return byRole }

        return all.filter {
            StringSanitizer.lower($0.path).contains(needle) || StringSanitizer.lower($0.name).contains(needle)
        }
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
    ) -> String {
        guard let mailboxID = row.mailboxID, let box = mailboxes[mailboxID] else { return "" }
        guard let url = emlxURL(mailboxURL: box.url, mailRoot: mailRoot, messageROWID: row.id) else { return "" }
        return parseEmlx(at: url).body
    }

    // MARK: - Models

    private struct MailDetail {
        let id: String
        let messageID: String?
        let subject: String
        let sender: String
        let recipients: String
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

    // MARK: - Single message

    private func makeDetailResponse(_ detail: MailDetail) -> ToolResponse {
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
            source: detail.body.isEmpty ? "Mail.app" : sourceName,
            preview: detail.body,
            metadata: metadata
        )
        return ToolResponse(ok: true, source: item.source, items: [item])
    }

    private func readMessageDetail(database: OpaquePointer, rowID: String, mailRoot: URL) throws -> MailDetail {
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

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MailStoreFailure("Message with id \(rowID) not found.")
        }

        let subject = textValue(statement, column: 2) ?? "(no subject)"
        let sender = textValue(statement, column: 3) ?? ""
        let date = dateValue(statement, column: 4)
        let isRead = boolValue(statement, column: 5)
        let mailboxID = textValue(statement, column: 6)

        var body = ""
        var recipients = ""

        if let mailboxID, let box = mailboxes[mailboxID],
           let emlxURL = emlxURL(mailboxURL: box.url, mailRoot: mailRoot, messageROWID: rowID) {
            let parsed = parseEmlx(at: emlxURL)
            body = parsed.body
            recipients = parsed.to
        }

        if body.isEmpty, let found = try findEmlxBySearch(mailRoot: mailRoot, messageROWID: rowID) {
            let parsed = parseEmlx(at: found)
            body = parsed.body
            if recipients.isEmpty { recipients = parsed.to }
        }

        if recipients.isEmpty {
            recipients = (try readRecipients(database: database, schema: schema, messageIDs: [rowID]))[rowID] ?? ""
        }

        let box = mailboxID.flatMap { mailboxes[$0] }
        return MailDetail(
            id: rowID,
            messageID: textValue(statement, column: 1),
            subject: subject,
            sender: sender,
            recipients: recipients,
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

        let candidates = [
            mailboxPath.appendingPathComponent("Messages/\(messageROWID).emlx"),
            mailboxPath.appendingPathComponent("Messages/\(messageROWID).partial.emlx"),
            mailboxPath.appendingPathComponent("\(messageROWID).emlx")
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func findEmlxBySearch(mailRoot: URL, messageROWID: String) throws -> URL? {
        let enumerator = fileManager.enumerator(
            at: mailRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let targetNames = Set(["\(messageROWID).emlx", "\(messageROWID).partial.emlx"])
        while let url = enumerator?.nextObject() as? URL {
            if targetNames.contains(url.lastPathComponent) {
                return url
            }
        }
        return nil
    }

    // MARK: - Store location

    private func locateEnvelopeIndex() throws -> URL {
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

        let candidates = versions
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && url.lastPathComponent.hasPrefix("V")
            }
            .sorted { lhs, rhs in
                versionNumber(lhs.lastPathComponent) > versionNumber(rhs.lastPathComponent)
            }
            .map { $0.appendingPathComponent("MailData/Envelope Index", isDirectory: false) }

        guard let index = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw MailStoreFailure("Mail Envelope Index was not found below \(mailRoot.path).")
        }

        return index
    }

    private func versionNumber(_ name: String) -> Int {
        Int(name.dropFirst()) ?? 0
    }

    // MARK: - .emlx parsing

    private func parseEmlx(at url: URL) -> (body: String, to: String) {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return ("", "")
        }

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

        let to = extractHeader(emailPart, name: "To")
        let body = extractBody(emailPart)
        let truncated = body.count > 8_000 ? String(body.prefix(8_000)) + "\n[truncated]" : body
        return (truncated, to)
    }

    private func extractHeader(_ email: String, name: String) -> String {
        let headerEnd = email.range(of: "\r\n\r\n") ?? email.range(of: "\n\n")
        let headerSection = headerEnd.map { String(email[email.startIndex..<$0.lowerBound]) } ?? email

        let pattern = "(?mi)^\(NSRegularExpression.escapedPattern(for: name)):\\s*(.+?)(?=\\n\\S|\\n\\n|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: headerSection, range: NSRange(headerSection.startIndex..., in: headerSection)),
              let range = Range(match.range(at: 1), in: headerSection) else {
            return ""
        }

        return headerSection[range]
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func extractBody(_ email: String) -> String {
        let separator = email.contains("\r\n\r\n") ? "\r\n\r\n" : "\n\n"
        guard let bodyRange = email.range(of: separator) else {
            return ""
        }

        let rawBody = String(email[bodyRange.upperBound...])

        let contentType = extractHeader(email, name: "Content-Type").lowercased()
        let transferEncoding = extractHeader(email, name: "Content-Transfer-Encoding").lowercased()

        var decoded = rawBody
        if transferEncoding.contains("quoted-printable") {
            decoded = decodeQuotedPrintable(decoded)
        } else if transferEncoding.contains("base64") {
            if let data = Data(base64Encoded: decoded.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: ""), options: .ignoreUnknownCharacters),
               let text = String(data: data, encoding: .utf8) {
                decoded = text
            }
        }

        if contentType.contains("text/html") {
            decoded = stripHTML(decoded)
        }

        if contentType.contains("multipart/") {
            decoded = extractMultipartText(rawBody, contentType: contentType)
        }

        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractMultipartText(_ body: String, contentType: String) -> String {
        let boundaryPattern = "boundary=\"?([^\";\\s]+)\"?"
        guard let regex = try? NSRegularExpression(pattern: boundaryPattern),
              let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
              let range = Range(match.range(at: 1), in: contentType) else {
            return body
        }

        let boundary = "--" + String(contentType[range])
        let parts = body.components(separatedBy: boundary)

        var plainText = ""
        var htmlText = ""

        for part in parts {
            let lower = part.lowercased()
            if lower.contains("content-type: text/plain") || lower.contains("content-type:text/plain") {
                let partBody = extractBody(part)
                if !partBody.isEmpty { plainText = partBody }
            } else if lower.contains("content-type: text/html") || lower.contains("content-type:text/html") {
                let partBody = extractBody(part)
                if !partBody.isEmpty { htmlText = stripHTML(partBody) }
            }
        }

        return plainText.isEmpty ? htmlText : plainText
    }

    private func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<p[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n")
        text = text.replacingOccurrences(of: "<div[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeQuotedPrintable(_ input: String) -> String {
        var result = input.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
        let pattern = "=([0-9A-Fa-f]{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let hexRange = Range(match.range(at: 1), in: result) else { continue }
            let hex = String(result[hexRange])
            if let byte = UInt8(hex, radix: 16) {
                result.replaceSubrange(fullRange, with: String(UnicodeScalar(byte)))
            }
        }
        return result
    }

    // MARK: - SQLite plumbing

    /// Read-only, always. Nothing in this provider is allowed to change the user's mail.
    private func withDatabase<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
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
        sqlite3_busy_timeout(database, 800)
        return try body(database)
    }

    private func tableColumns(database: OpaquePointer, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MailStoreFailure("Could not inspect Mail index schema: \(databaseMessage(database))")
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

    private static func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    @discardableResult
    private func bind(_ values: [String], to statement: OpaquePointer, from start: Int32) -> Int32 {
        var index = start
        for value in values {
            sqlite3_bind_text(statement, index, value, -1, transientDestructor())
            index += 1
        }
        return index
    }

    private func textValue(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else {
            return nil
        }
        return String(cString: value)
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
        if value <= 0 {
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

    // MARK: - AppleScript fallback

    /// Used only when the index is unreadable. It covers the inbox, sent and drafts mailboxes and says
    /// so in `meta.coverage`, because a fallback that quietly searches less than the primary path is
    /// the same silent-truncation failure in a different costume.
    private func appleScriptSearch(request: SearchRequest) async -> ToolResponse {
        let escaped = escapeForAppleScript(request.query)
        let sinceClause: String
        if request.sinceHours > 0 {
            sinceClause = """
            set _cutoff to (current date) - (\(request.sinceHours) * 3600)
            """
        } else {
            sinceClause = "set _cutoff to missing value"
        }

        let wanted = request.limit + request.offset
        let script = """
        \(sinceClause)
        set _limit to \(wanted)
        set _query to "\(escaped)"
        set _unreadOnly to \(request.unreadOnly ? "true" : "false")
        set _out to ""
        set _count to 0
        tell application "Mail"
            set _boxes to {inbox} & sent mailbox & drafts mailbox
            repeat with _box in _boxes
                if _count >= _limit then exit repeat
                try
                    set _msgs to messages of _box
                    set _total to count of _msgs
                    if _total > 500 then set _total to 500
                    repeat with _i from 1 to _total
                        if _count >= _limit then exit repeat
                        set _msg to item _i of _msgs
                        try
                            set _subj to subject of _msg
                            set _from to sender of _msg
                            set _dateR to date received of _msg
                            set _readS to read status of _msg
                            set _msgId to message id of _msg

                            set _skip to false
                            if _unreadOnly and _readS then set _skip to true
                            if _cutoff is not missing value and _dateR < _cutoff then set _skip to true

                            if not _skip then
                                if _query is "" then
                                    set _match to true
                                else
                                    set _match to false
                                    ignoring case
                                        if _subj contains _query then set _match to true
                                        if _from contains _query then set _match to true
                                    end ignoring
                                end if

                                if _match then
                                    set _dateStr to (_dateR as «class isot» as string)
                                    set _readStr to "false"
                                    if _readS then set _readStr to "true"
                                    set _out to _out & _msgId & tab & _subj & tab & _from & tab & _dateStr & tab & _readStr & linefeed
                                    set _count to _count + 1
                                end if
                            end if
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return _out
        """

        let result = await AppleScriptRunner.run(script, timeout: 20)
        switch result {
        case .success(let output):
            let all = parseAppleScriptSearchRows(output)
            let items = Array(all.dropFirst(request.offset).prefix(request.limit))
            let capped = all.count >= wanted
            var message: String?
            if items.isEmpty {
                message = "No matching messages found via Mail.app."
            } else if capped {
                message = "Mail.app fallback: reached its scan bound, so this may not be the whole result set."
            }
            return ToolResponse(
                ok: true,
                source: "Mail.app",
                items: items,
                message: message,
                meta: [
                    "returned": String(items.count),
                    "offset": String(request.offset),
                    "limit": String(request.limit),
                    "total": String(all.count),
                    "total_exact": "false",
                    "has_more": String(capped),
                    "truncated": String(capped),
                    "coverage": "inbox,sent,drafts",
                    "fields": "subject,sender",
                    "match": "phrase",
                    "recipients_searchable": "false",
                    "body_searchable": "false",
                    "fallback": "applescript"
                ]
            )
        case .failure(let error):
            return ToolResponse(
                ok: false,
                source: "Mail.app",
                message: "Mail.app is not accessible. Grant Automation permission for Mail.app, then retry. \(StringSanitizer.compact(error.message, limit: 400))"
            )
        }
    }

    private func appleScriptRead(messageID: String) async -> ToolResponse {
        let escaped = escapeForAppleScript(messageID)

        let script = """
        set _targetId to "\(escaped)"
        set _out to ""
        tell application "Mail"
            set _boxes to every mailbox of every account
            set _found to false
            repeat with _acctBoxes in _boxes
                if _found then exit repeat
                repeat with _box in _acctBoxes
                    if _found then exit repeat
                    try
                        set _msgs to (messages of _box whose message id is _targetId)
                        if (count of _msgs) > 0 then
                            set _msg to item 1 of _msgs
                            set _subj to subject of _msg
                            set _from to sender of _msg
                            set _dateR to date received of _msg
                            set _readS to read status of _msg
                            set _msgId to message id of _msg
                            set _body to content of _msg
                            set _dateStr to (_dateR as «class isot» as string)
                            set _readStr to "false"
                            if _readS then set _readStr to "true"

                            set _toList to ""
                            try
                                set _tos to to recipients of _msg
                                repeat with _r in _tos
                                    if _toList is not "" then set _toList to _toList & ", "
                                    set _toList to _toList & (address of _r as text)
                                end repeat
                            end try

                            if length of _body > 8000 then set _body to text 1 thru 8000 of _body

                            set AppleScript's text item delimiters to linefeed
                            set _bodyParts to text items of _body
                            set AppleScript's text item delimiters to "\\n"
                            set _bodyClean to _bodyParts as text
                            set AppleScript's text item delimiters to ""

                            set _out to _msgId & tab & _subj & tab & _from & tab & _dateStr & tab & _readStr & tab & _toList & tab & _bodyClean
                            set _found to true
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return _out
        """

        let result = await AppleScriptRunner.run(script, timeout: 20)
        switch result {
        case .success(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ToolResponse(ok: false, source: "Mail.app", message: "Message not found in Mail.app.")
            }
            let detail = parseAppleScriptReadRow(trimmed)
            return makeDetailResponse(detail)
        case .failure(let error):
            return ToolResponse(
                ok: false,
                source: "Mail.app",
                message: "Could not read message via Mail.app. \(StringSanitizer.compact(error.message, limit: 400))"
            )
        }
    }

    private func parseAppleScriptSearchRows(_ output: String) -> [DataItem] {
        output
            .split(separator: "\n")
            .compactMap { row in
                let cols = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard cols.count >= 5 else { return nil }

                let messageID = cols[0]
                let subject = cols[1]
                let sender = cols[2]
                let dateStr = cols[3]
                let readStr = cols[4]

                var metadata: [String: String] = [
                    "sender": sender,
                    "message_id": messageID,
                    "read": readStr,
                    "mailbox_role": "unknown"
                ]
                if !dateStr.isEmpty {
                    metadata["received"] = dateStr
                }

                return DataItem(
                    id: "as:\(messageID)",
                    title: subject.isEmpty ? "(no subject)" : subject,
                    subtitle: sender,
                    kind: "mail_message",
                    source: "Mail.app",
                    metadata: metadata
                )
            }
    }

    private func parseAppleScriptReadRow(_ row: String) -> MailDetail {
        let cols = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)

        let messageID = cols.count > 0 ? cols[0] : ""
        let subject = cols.count > 1 ? cols[1] : "(no subject)"
        let sender = cols.count > 2 ? cols[2] : ""
        let dateStr = cols.count > 3 ? cols[3] : ""
        let readStr = cols.count > 4 ? cols[4] : ""
        let recipients = cols.count > 5 ? cols[5] : ""
        let body = cols.count > 6 ? cols[6].replacingOccurrences(of: "\\n", with: "\n") : ""

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: dateStr)

        return MailDetail(
            id: "as:\(messageID)",
            messageID: messageID,
            subject: subject,
            sender: sender,
            recipients: recipients,
            receivedDate: date,
            isRead: readStr == "true" ? true : readStr == "false" ? false : nil,
            body: body,
            mailbox: nil,
            mailboxRole: nil
        )
    }

    private func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
