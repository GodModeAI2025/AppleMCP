import Foundation
import M3MCPCore
import SQLite3

final class MailProvider {
    private let fileManager = FileManager.default

    func search(input: [String: JSONValue]) async -> ToolResponse {
        let rawQuery = input.string("query")
        let limit = max(1, min(input.int("limit", default: 20), 50))
        let queryIntent = parseQueryIntent(rawQuery)
        let unreadOnly = input.bool("unread_only", default: queryIntent.unreadOnly)
        let sinceHours = max(0, input.int("since_hours", default: queryIntent.sinceHours ?? 0))
        let maxCandidates = max(limit, min(input.int("max_candidates", default: 500), 2_000))

        do {
            let indexURL = try locateEnvelopeIndex()
            let rows = try readMessages(
                from: indexURL,
                query: queryIntent.query,
                unreadOnly: unreadOnly,
                sinceHours: sinceHours,
                maxCandidates: maxCandidates
            )
            .prefix(limit)

            let items = rows.map(makeItem)
            let message = items.isEmpty ? "No matching messages found in the local Mail index." : nil
            return ToolResponse(ok: true, source: "Mail Local Index", items: Array(items), message: message)
        } catch {
            return await appleScriptSearch(
                query: queryIntent.query,
                unreadOnly: unreadOnly,
                sinceHours: sinceHours,
                limit: limit
            )
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

        let item = DataItem(
            id: detail.id,
            title: detail.subject.isEmpty ? "(no subject)" : detail.subject,
            subtitle: detail.sender,
            kind: "mail_message",
            source: detail.body.isEmpty ? "Mail.app" : "Mail Local Index",
            preview: detail.body,
            metadata: metadata
        )
        return ToolResponse(ok: true, source: item.source, items: [item])
    }

    private struct MailDetail {
        let id: String
        let messageID: String?
        let subject: String
        let sender: String
        let recipients: String
        let receivedDate: Date?
        let isRead: Bool?
        let body: String
    }

    private struct MailRow {
        let id: String
        let messageID: String?
        let subject: String
        let sender: String
        let receivedDate: Date?
        let isRead: Bool?
    }

    private struct MailStoreFailure: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    private func parseQueryIntent(_ rawQuery: String) -> (query: String, unreadOnly: Bool, sinceHours: Int?) {
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

    private func parseSinceHours(_ lowerQuery: String) -> Int? {
        if lowerQuery.contains("last 24") || lowerQuery.contains("24h") || lowerQuery.contains("24 stunden") {
            return 24
        }

        if lowerQuery.contains("today") || lowerQuery.contains("heute") {
            return 24
        }

        return nil
    }

    private func locateEnvelopeIndex() throws -> URL {
        let mailRoot = fileManager.homeDirectoryForCurrentUser
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

    private func readMessages(
        from indexURL: URL,
        query: String,
        unreadOnly: Bool,
        sinceHours: Int,
        maxCandidates: Int
    ) throws -> [MailRow] {
        try withDatabase(at: indexURL) { database in
            let columns = try tableColumns(database: database, table: "messages")
            guard !columns.isEmpty else {
                throw MailStoreFailure("Mail index is readable, but the messages table was not found.")
            }

            let subjectColumn = pick(columns, ["subject"])
            let senderColumn = pick(columns, ["sender"])
            let messageIDColumn = pick(columns, ["message_id", "messageid"])
            let dateColumn = pick(columns, ["date_received", "dateReceived", "date_sent", "dateSent", "date_created"])
            let readColumn = pick(columns, ["read", "is_read", "isRead"])
            let deletedColumn = pick(columns, ["deleted", "is_deleted", "isDeleted"])
            let junkColumn = pick(columns, ["junk", "is_junk", "isJunk"])

            let subjectsTable = try tableColumns(database: database, table: "subjects")
            let addressesTable = try tableColumns(database: database, table: "addresses")

            let hasSubjectsLookup = !subjectsTable.isEmpty && subjectsTable.contains("subject") && subjectColumn != nil
            let hasAddressesLookup = !addressesTable.isEmpty && addressesTable.contains("address") && senderColumn != nil
            let addressCommentColumn = hasAddressesLookup && addressesTable.contains("comment") ? "comment" : nil

            guard !unreadOnly || readColumn != nil else {
                throw MailStoreFailure("Unread filtering is not available in this Mail index schema.")
            }

            var joins: [String] = []

            let subjectExpr: String
            if hasSubjectsLookup {
                joins.append("LEFT JOIN subjects ON messages.\(quote(subjectColumn!)) = subjects.ROWID")
                subjectExpr = "subjects.\(quote("subject"))"
            } else {
                subjectExpr = subjectColumn.map { "messages.\(quote($0))" } ?? "''"
            }

            let senderExpr: String
            if hasAddressesLookup {
                joins.append("LEFT JOIN addresses ON messages.\(quote(senderColumn!)) = addresses.ROWID")
                if let commentCol = addressCommentColumn {
                    senderExpr = "COALESCE(addresses.\(quote(commentCol)), addresses.\(quote("address")), '')"
                } else {
                    senderExpr = "COALESCE(addresses.\(quote("address")), '')"
                }
            } else {
                senderExpr = senderColumn.map { "messages.\(quote($0))" } ?? "''"
            }

            var predicates: [String] = []
            var bindings: [String] = []

            if let deletedColumn {
                predicates.append("(messages.\(quote(deletedColumn)) = 0 OR messages.\(quote(deletedColumn)) IS NULL)")
            }

            if let junkColumn {
                predicates.append("(messages.\(quote(junkColumn)) = 0 OR messages.\(quote(junkColumn)) IS NULL)")
            }

            if unreadOnly, let readColumn {
                predicates.append("messages.\(quote(readColumn)) = 0")
            }

            if !query.isEmpty {
                var searchClauses: [String] = []
                if hasSubjectsLookup {
                    searchClauses.append("lower(\(subjectExpr)) LIKE ?")
                } else if subjectColumn != nil {
                    searchClauses.append("lower(messages.\(quote(subjectColumn!))) LIKE ?")
                }
                if hasAddressesLookup {
                    searchClauses.append("lower(\(senderExpr)) LIKE ?")
                } else if senderColumn != nil {
                    searchClauses.append("lower(messages.\(quote(senderColumn!))) LIKE ?")
                }
                if !searchClauses.isEmpty {
                    predicates.append("(" + searchClauses.joined(separator: " OR ") + ")")
                    bindings.append(contentsOf: Array(repeating: "%\(query.localizedLowercase)%", count: searchClauses.count))
                }
            }

            let dateExpr = dateColumn.map { "messages.\(quote($0))" }
            let messageIDExpr = messageIDColumn.map { "messages.\(quote($0))" } ?? "NULL"
            let readExpr = readColumn.map { "messages.\(quote($0))" } ?? "NULL"

            var sql = """
            SELECT
              messages.ROWID,
              \(messageIDExpr),
              \(subjectExpr),
              \(senderExpr),
              \(dateExpr ?? "NULL"),
              \(readExpr)
            FROM messages
            """

            for join in joins {
                sql += " " + join
            }

            if !predicates.isEmpty {
                sql += " WHERE " + predicates.joined(separator: " AND ")
            }

            sql += " ORDER BY \(dateExpr ?? "messages.ROWID") DESC LIMIT ?"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw MailStoreFailure("Could not query Mail index: \(databaseMessage(database))")
            }
            defer { sqlite3_finalize(statement) }

            var bindIndex: Int32 = 1
            for value in bindings {
                sqlite3_bind_text(statement, bindIndex, value, -1, transientDestructor())
                bindIndex += 1
            }
            sqlite3_bind_int(statement, bindIndex, Int32(maxCandidates))

            var rows: [MailRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let date = dateValue(statement, column: 4)
                if sinceHours > 0 {
                    guard let date, date >= Date().addingTimeInterval(-Double(sinceHours) * 60 * 60) else {
                        continue
                    }
                }

                rows.append(
                    MailRow(
                        id: textValue(statement, column: 0) ?? UUID().uuidString,
                        messageID: textValue(statement, column: 1),
                        subject: textValue(statement, column: 2) ?? "(no subject)",
                        sender: textValue(statement, column: 3) ?? "",
                        receivedDate: date,
                        isRead: boolValue(statement, column: 5)
                    )
                )
            }

            return rows
        }
    }

    private func makeItem(_ row: MailRow) -> DataItem {
        var metadata: [String: String] = [
            "sender": row.sender
        ]

        if let messageID = row.messageID, !messageID.isEmpty {
            metadata["message_id"] = messageID
        }

        if let receivedDate = row.receivedDate {
            metadata["received"] = ISO8601DateFormatter().string(from: receivedDate)
        }

        if let isRead = row.isRead {
            metadata["read"] = String(isRead)
        }

        return DataItem(
            id: row.id,
            title: row.subject.isEmpty ? "(no subject)" : row.subject,
            subtitle: row.sender,
            kind: "mail_message",
            source: "Mail Local Index",
            metadata: metadata
        )
    }

    private func readMessageDetail(database: OpaquePointer, rowID: String, mailRoot: URL) throws -> MailDetail {
        let columns = try tableColumns(database: database, table: "messages")
        guard !columns.isEmpty else {
            throw MailStoreFailure("Mail index is readable, but the messages table was not found.")
        }

        let subjectColumn = pick(columns, ["subject"])
        let senderColumn = pick(columns, ["sender"])
        let messageIDColumn = pick(columns, ["message_id", "messageid"])
        let dateColumn = pick(columns, ["date_received", "dateReceived", "date_sent", "dateSent", "date_created"])
        let readColumn = pick(columns, ["read", "is_read", "isRead"])
        let mailboxColumn = pick(columns, ["mailbox"])

        let subjectsTable = try tableColumns(database: database, table: "subjects")
        let addressesTable = try tableColumns(database: database, table: "addresses")

        let hasSubjectsLookup = !subjectsTable.isEmpty && subjectsTable.contains("subject") && subjectColumn != nil
        let hasAddressesLookup = !addressesTable.isEmpty && addressesTable.contains("address") && senderColumn != nil
        let addressCommentColumn = hasAddressesLookup && addressesTable.contains("comment") ? "comment" : nil

        let subjectExpr: String
        var joins: [String] = []
        if hasSubjectsLookup {
            joins.append("LEFT JOIN subjects ON messages.\(quote(subjectColumn!)) = subjects.ROWID")
            subjectExpr = "subjects.\(quote("subject"))"
        } else {
            subjectExpr = subjectColumn.map { "messages.\(quote($0))" } ?? "''"
        }

        let senderExpr: String
        if hasAddressesLookup {
            joins.append("LEFT JOIN addresses ON messages.\(quote(senderColumn!)) = addresses.ROWID")
            if let commentCol = addressCommentColumn {
                senderExpr = "COALESCE(addresses.\(quote(commentCol)), addresses.\(quote("address")), '')"
            } else {
                senderExpr = "COALESCE(addresses.\(quote("address")), '')"
            }
        } else {
            senderExpr = senderColumn.map { "messages.\(quote($0))" } ?? "''"
        }

        let dateExpr = dateColumn.map { "messages.\(quote($0))" } ?? "NULL"
        let messageIDExpr = messageIDColumn.map { "messages.\(quote($0))" } ?? "NULL"
        let readExpr = readColumn.map { "messages.\(quote($0))" } ?? "NULL"
        let mailboxExpr = mailboxColumn.map { "messages.\(quote($0))" } ?? "NULL"

        var sql = """
        SELECT
          messages.ROWID,
          \(messageIDExpr),
          \(subjectExpr),
          \(senderExpr),
          \(dateExpr),
          \(readExpr),
          \(mailboxExpr)
        FROM messages
        """

        for join in joins {
            sql += " " + join
        }

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

        if let mailboxID {
            let emlxURL = try resolveEmlxPath(database: database, mailRoot: mailRoot, mailboxID: mailboxID, messageROWID: rowID)
            if let emlxURL, fileManager.fileExists(atPath: emlxURL.path) {
                let parsed = parseEmlx(at: emlxURL)
                body = parsed.body
                recipients = parsed.to
            }
        }

        if body.isEmpty {
            let found = try findEmlxBySearch(mailRoot: mailRoot, messageROWID: rowID)
            if let found {
                let parsed = parseEmlx(at: found)
                body = parsed.body
                if recipients.isEmpty { recipients = parsed.to }
            }
        }

        return MailDetail(
            id: rowID,
            messageID: textValue(statement, column: 1),
            subject: subject,
            sender: sender,
            recipients: recipients,
            receivedDate: date,
            isRead: isRead,
            body: body.isEmpty ? "(body not available — .emlx file not found)" : body
        )
    }

    private func resolveEmlxPath(database: OpaquePointer, mailRoot: URL, mailboxID: String, messageROWID: String) throws -> URL? {
        let mailboxColumns = try tableColumns(database: database, table: "mailboxes")
        guard !mailboxColumns.isEmpty else { return nil }

        let urlColumn = pick(mailboxColumns, ["url"])
        guard let urlColumn else { return nil }

        let sql = "SELECT \(quote(urlColumn)) FROM mailboxes WHERE ROWID = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, mailboxID, -1, transientDestructor())

        guard sqlite3_step(statement) == SQLITE_ROW,
              let rawURL = textValue(statement, column: 0) else {
            return nil
        }

        let mailboxPath: URL
        if rawURL.hasPrefix("file://") || rawURL.hasPrefix("/") {
            if rawURL.hasPrefix("file://") {
                guard let u = URL(string: rawURL) else { return nil }
                mailboxPath = u
            } else {
                mailboxPath = URL(fileURLWithPath: rawURL)
            }
        } else {
            mailboxPath = mailRoot.appendingPathComponent(rawURL, isDirectory: true)
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

    private func boolValue(_ statement: OpaquePointer, column: Int32) -> Bool? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int(statement, column) != 0
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

    private func appleScriptSearch(query: String, unreadOnly: Bool, sinceHours: Int, limit: Int) async -> ToolResponse {
        let escaped = escapeForAppleScript(query)
        let sinceClause: String
        if sinceHours > 0 {
            sinceClause = """
            set _cutoff to (current date) - (\(sinceHours) * 3600)
            """
        } else {
            sinceClause = "set _cutoff to missing value"
        }

        let script = """
        \(sinceClause)
        set _limit to \(limit)
        set _query to "\(escaped)"
        set _unreadOnly to \(unreadOnly ? "true" : "false")
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
            let items = parseAppleScriptSearchRows(output)
            let message = items.isEmpty ? "No matching messages found via Mail.app." : nil
            return ToolResponse(ok: true, source: "Mail.app", items: items, message: message)
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
                    "read": readStr
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
            body: body
        )
    }

    private func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
