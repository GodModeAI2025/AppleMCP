import Foundation
import M3MCPCore
import SQLite3
import XCTest
@testable import M3MCPApp

/// What `mail_search` actually matches, measured against a synthetic Envelope Index.
///
/// The provider reads a real SQLite database, a real `subjects`/`addresses`/`recipients` schema, and
/// real `.emlx` files on disk. Only the location is redirected, through the same environment
/// override the existing Mail tests use. Nothing here needs Full Disk Access or a Mail account, so
/// it runs everywhere the rest of the suite runs.
final class MailProviderSearchSemanticsTests: XCTestCase {
    private var fixture: MailFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try MailFixture()
    }

    override func tearDownWithError() throws {
        fixture?.tearDown()
        fixture = nil
        try super.tearDownWithError()
    }

    private func search(_ overrides: [String: JSONValue]) async -> ToolResponse {
        var input: [String: JSONValue] = [
            // The intent parser rewrites the query from its own wording. Off, so these assertions
            // are about matching and not about parsing.
            "auto_intent": .bool(false),
            "limit": .number(50),
            "max_candidates": .number(500)
        ]
        for (key, value) in overrides {
            input[key] = value
        }
        return await fixture.withMailRoot { await MailProvider().search(input: input) }
    }

    // MARK: - Term semantics

    func testAllRequiresEveryTermAndAnyRequiresOnlyOne() async {
        let all = await search([
            "query": .string("quarterly invoice"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertTrue(all.ok, all.message ?? "")
        XCTAssertEqual(all.items.map(\.id), ["1"])

        // One term in one message, the other in a different one. Neither message holds both.
        let noneHoldBoth = await search([
            "query": .string("quarterly travel"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertTrue(noneHoldBoth.items.isEmpty, "match=all must not join terms across messages")

        let any = await search([
            "query": .string("quarterly travel"),
            "match": .string("any"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(Set(any.items.map(\.id)), ["1", "3"])
    }

    func testPhraseKeepsTheWordOrderThatAllThrowsAway() async {
        let phrase = await search([
            "query": .string("quarterly invoice"),
            "match": .string("phrase"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(phrase.items.map(\.id), ["1"])

        let reversed = await search([
            "query": .string("invoice quarterly"),
            "match": .string("phrase"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertTrue(reversed.items.isEmpty, "a phrase is one string, not a set of words")

        // The same reversed words under match=all still match, which is the whole point of having
        // both modes.
        let reorderedTerms = await search([
            "query": .string("invoice quarterly"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(reorderedTerms.items.map(\.id), ["1"])
    }

    func testAnUnknownMatchModeIsRefusedRatherThanSilentlyTreatedAsAll() async {
        let response = await search([
            "query": .string("invoice"),
            "match": .string("regex")
        ])
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("all, any, phrase") == true, response.message ?? "")
    }

    // MARK: - Fields

    func testAnAddressBehindADisplayNameStaysSearchable() async {
        // The address is only in `addresses.address`; the display name is in `addresses.comment`.
        // Matching on the displayed string alone would make this address unfindable.
        let byAddress = await search([
            "query": .string("anna.beispiel@example.test"),
            "fields": .array([.string("sender")])
        ])
        XCTAssertEqual(byAddress.items.map(\.id), ["1"])
        XCTAssertEqual(byAddress.items.first?.metadata["fields_matched"], "sender")

        let byDisplayName = await search([
            "query": .string("Anna Beispiel"),
            "fields": .array([.string("sender")])
        ])
        XCTAssertEqual(byDisplayName.items.map(\.id), ["1"])
    }

    func testRecipientsAreSearchedThroughTheirOwnTable() async {
        let response = await search([
            "query": .string("carla@example.test"),
            "fields": .array([.string("recipients")])
        ])
        XCTAssertEqual(response.items.map(\.id), ["2"])
        XCTAssertEqual(response.items.first?.metadata["fields_matched"], "recipients")

        // And the same term is not found when recipients are not among the requested fields.
        let scoped = await search([
            "query": .string("carla@example.test"),
            "fields": .array([.string("subject"), .string("sender")])
        ])
        XCTAssertTrue(scoped.items.isEmpty, "a field the caller did not ask for must not be matched")
    }

    func testABodyOnlyHitSurvivesBeingAskedForAlongsideASubject() async {
        // The body is not in the index, so a term predicate built from the index-backed fields alone
        // would have decided this message was not a candidate before its .emlx was ever opened.
        let response = await search([
            "query": .string("bodyneedle"),
            "fields": .array([.string("subject"), .string("body")])
        ])
        XCTAssertEqual(response.items.map(\.id), ["3"])
        XCTAssertEqual(response.items.first?.metadata["fields_matched"], "body")
        XCTAssertEqual(response.meta?["total_exact"], "true")
    }

    func testFieldsOutsideTheDocumentedFourAreRefused() async {
        let response = await search([
            "query": .string("invoice"),
            "fields": .array([.string("headers")])
        ])
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("documented four names") == true, response.message ?? "")
    }

    // MARK: - Structural filters

    func testUnreadJunkAndDeletedAreFilteredInSQL() async {
        let everything = await search([
            "query": .string("newsletter"),
            "fields": .array([.string("subject")]),
            "include_junk": .bool(true)
        ])
        // Row 6 is deleted and must never appear, junk or not.
        XCTAssertEqual(Set(everything.items.map(\.id)), ["4", "5"])

        let withoutJunk = await search([
            "query": .string("newsletter"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(withoutJunk.items.map(\.id), ["4"])

        let unreadOnly = await search([
            "query": .string("newsletter"),
            "fields": .array([.string("subject")]),
            "include_junk": .bool(true),
            "unread_only": .bool(true)
        ])
        XCTAssertEqual(unreadOnly.items.map(\.id), ["5"])
    }

    func testSinceHoursUnderstandsBothDateEncodingsInOneStore() async {
        // Mail has written this column as a Unix epoch and as a Core Foundation reference date
        // depending on the schema version. Reading one of them as the other puts every message
        // decades out of range, and the filter then quietly returns nothing.
        let recent = await search([
            "query": .string("timestamp"),
            "fields": .array([.string("subject")]),
            "since_hours": .number(24)
        ])
        XCTAssertEqual(Set(recent.items.map(\.id)), ["7", "8"], "one row is epoch-dated, the other reference-dated")

        let all = await search([
            "query": .string("timestamp"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertEqual(Set(all.items.map(\.id)), ["7", "8", "9", "10"])
    }

    func testTheMailboxFilterReportsHowManyMailboxesItMatched() async {
        let response = await search([
            "query": .string("quarterly"),
            "fields": .array([.string("subject")]),
            "mailbox": .string("Archive")
        ])
        XCTAssertTrue(response.items.isEmpty, "message 1 is in the Inbox, not the Archive")
        XCTAssertEqual(response.meta?["mailbox_filter_matched"], "1")

        let unmatched = await search([
            "query": .string("quarterly"),
            "fields": .array([.string("subject")]),
            "mailbox": .string("no-such-mailbox")
        ])
        XCTAssertTrue(unmatched.items.isEmpty)
        XCTAssertEqual(unmatched.meta?["mailbox_filter_matched"], "0")
    }

    // MARK: - Date range filters

    /// ISO 8601 stamp with the machine's local zone, the zone the provider resolves zoneless
    /// input in. The instant is what matters; the zone designator only makes it unambiguous.
    private func isoStamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = Calendar.current.timeZone
        return formatter.string(from: date)
    }

    /// Core regression: the date column mixes Unix epoch seconds and Core Data reference-date
    /// seconds, so the range filter must carry both SQL branches. A single-branch filter would
    /// silently drop either the epoch-dated or the reference-dated row.
    func testDateRangeMatchesBothEpochs() async {
        let now = Date()
        let response = await search([
            "query": .string("timestamp"),
            "fields": .array([.string("subject")]),
            "date_from": .string(isoStamp(now.addingTimeInterval(-3_600))),
            "date_to": .string(isoStamp(now))
        ])
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(Set(response.items.map(\.id)), ["7", "8"], "one row is epoch-dated, the other reference-dated")
        XCTAssertEqual(response.meta?["time_filter"], "date_range")
    }

    /// date_to is inclusive and, for the short forms, the END of the named period: a message
    /// at 23:30 must survive date_to naming its own day. Truncating at midnight would drop it.
    func testDateToIncludesTheWholeDay() async {
        let response = await search([
            "query": .string("evening"),
            "fields": .array([.string("subject")]),
            "date_to": .string("2025-12-31")
        ])
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(response.items.map(\.id), ["14"])
    }

    /// The short forms are the main use case: date_from=2025 and date_to=2025 must cover
    /// 1 January through 31 December inclusive, and must not reach into the following year.
    func testShortFormsResolveToPeriodEdges() async {
        let response = await search([
            "query": .string("memo"),
            "fields": .array([.string("subject")]),
            "date_from": .string("2025"),
            "date_to": .string("2025")
        ])
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(Set(response.items.map(\.id)), ["13", "14"], "1 January and 31 December both belong to 2025")
        XCTAssertFalse(response.items.contains { $0.id == "15" }, "1 January 2026 is not part of 2025")
    }

    /// An invalid input must throw at parse time, never degrade into an empty result set: for
    /// an archival search "no hits" looks like a result.
    func testInvalidDateFailsClosed() async {
        for raw in ["2025-02-30", "gestern", "17.03.2025"] {
            let response = await search([
                "query": .string("memo"),
                "date_from": .string(raw)
            ])
            XCTAssertFalse(response.ok, "\(raw) must fail closed, not return nothing")
            XCTAssertTrue(
                response.message?.contains("Mail date_from and date_to accept") == true,
                "\(raw): \(response.message ?? "")"
            )
        }
    }

    /// date_from after date_to is an invocation error, not a filter that happens to match
    /// nothing. Both resolved instants belong in the message.
    func testReversedRangeIsAnError() async {
        let response = await search([
            "query": .string("memo"),
            "date_from": .string("2025-06"),
            "date_to": .string("2025-03")
        ])
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("2025-06-01") == true, response.message ?? "")
        XCTAssertTrue(response.message?.contains("2025-03-31") == true, response.message ?? "")
    }

    /// A since_hours above zero next to an absolute range is an invocation error, not a silent
    /// AND of two conflicting time filters.
    func testExplicitSinceHoursWithRangeIsAnError() async {
        let response = await search([
            "query": .string("memo"),
            "date_from": .string("2025"),
            "date_to": .string("2025"),
            "since_hours": .number(24)
        ])
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("since_hours") == true, response.message ?? "")
    }

    /// A present-but-zero since_hours is not a competing filter, because the predicate only fires
    /// above zero. Rejecting it would refuse a correct call from any client that pads optional
    /// arguments with their defaults, which is what a model typically does.
    func testZeroSinceHoursDoesNotConflictWithRange() async {
        let response = await search([
            "query": .string("timestamp"),
            "fields": .array([.string("subject")]),
            "date_from": .string("2025"),
            "date_to": .string("2025"),
            "since_hours": .number(0)
        ])
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(response.meta?["time_filter"], "date_range")
    }

    /// A since_hours that auto_intent derived from the query text yields to the
    /// absolute range instead of silently ANDing into an empty set. meta.time_filter says
    /// which filter won. The query uses "letzte 24h" because the intent cleaner removes that
    /// phrase but keeps "heute" as a literal term, which would break match=all for reasons
    /// unrelated to the date range.
    func testAutoIntentSinceHoursYieldsToRange() async {
        let response = await search([
            "query": .string("memo letzte 24h"),
            "fields": .array([.string("subject")]),
            "auto_intent": .bool(true),
            "date_from": .string("2025"),
            "date_to": .string("2025")
        ])
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(Set(response.items.map(\.id)), ["13", "14"])
        XCTAssertEqual(response.meta?["time_filter"], "date_range")
        XCTAssertEqual(response.meta?["since_hours"], "0", "the auto-intent window was discarded")
    }

    /// Without a date column an unfiltered search keeps working; a requested range fails closed
    /// with a clear message instead of silently searching everything.
    func testMissingDateColumnFailsClosed() async throws {
        let plain = try MailFixture(withDateColumn: false)
        defer { plain.tearDown() }

        let unfiltered = await plain.withMailRoot {
            await MailProvider().search(input: [
                "query": .string("quarterly"),
                "fields": .array([.string("subject")])
            ])
        }
        XCTAssertTrue(unfiltered.ok, unfiltered.message ?? "")
        XCTAssertEqual(unfiltered.items.map(\.id), ["1"])

        let ranged = await plain.withMailRoot {
            await MailProvider().search(input: [
                "query": .string("quarterly"),
                "date_from": .string("2025")
            ])
        }
        XCTAssertFalse(ranged.ok)
        XCTAssertTrue(
            ranged.message?.contains("Date filtering is not available") == true,
            ranged.message ?? ""
        )
    }

    /// meta.date_*_applied shows the instant the short form actually resolved to, including the
    /// zone: without it the end-of-day rule for date_to would be invisible.
    func testAppliedBoundsInMetadata() async {
        let response = await search([
            "query": .string("memo"),
            "date_from": .string("2025"),
            "date_to": .string("2025")
        ])
        XCTAssertTrue(response.ok, response.message ?? "")
        let fromApplied = response.meta?["date_from_applied"] ?? ""
        let toApplied = response.meta?["date_to_applied"] ?? ""
        XCTAssertTrue(fromApplied.hasPrefix("2025-01-01T00:00:00"), fromApplied)
        XCTAssertTrue(toApplied.hasPrefix("2025-12-31T23:59:59"), toApplied)
        XCTAssertEqual(response.meta?["time_filter"], "date_range")
        XCTAssertEqual(response.meta?["date_from"], "2025")
        XCTAssertEqual(response.meta?["date_to"], "2025")
    }

    // MARK: - Flag metadata and filters

    func testFlagMetadataInSearchResults() async {
        let lila = await search([
            "query": .string("quarterly"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertTrue(lila.ok, lila.message ?? "")
        XCTAssertEqual(lila.items.map(\.id), ["1"])
        XCTAssertEqual(lila.items.first?.metadata["flagged"], "true")
        XCTAssertEqual(lila.items.first?.metadata["flag_color"], "5")
        XCTAssertEqual(lila.items.first?.metadata["flag_color_name"], "purple")

        // Leftover-code caveat: the row still carries a former colour code in the bits but is
        // not marked, so flag_color metadata must only appear when flagged = 1.
        let restCode = await search([
            "query": .string("rechnung"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertTrue(restCode.ok, restCode.message ?? "")
        XCTAssertEqual(restCode.items.map(\.id), ["2"])
        XCTAssertEqual(restCode.items.first?.metadata["flagged"], "false")
        XCTAssertNil(restCode.items.first?.metadata["flag_color"])
        XCTAssertNil(restCode.items.first?.metadata["flag_color_name"])
    }

    func testFlaggedOnlyFilter() async {
        let flaggedOnly = await search(["flagged_only": .bool(true)])
        XCTAssertTrue(flaggedOnly.ok, flaggedOnly.message ?? "")
        XCTAssertEqual(Set(flaggedOnly.items.map(\.id)), ["1", "3", "4"])
        XCTAssertEqual(flaggedOnly.meta?["flagged_only"], "true")

        // The leftover-code row (flagged = 0, code 5) stays excluded even without a colour filter.
        XCTAssertFalse(flaggedOnly.items.contains { $0.id == "2" })

        let withQuery = await search([
            "query": .string("newsletter"),
            "fields": .array([.string("subject")]),
            "flagged_only": .bool(true)
        ])
        XCTAssertTrue(withQuery.ok, withQuery.message ?? "")
        XCTAssertEqual(withQuery.items.map(\.id), ["4"])
    }

    /// Core regression: the colour filter must actually find the marked purple row, not merely
    /// run without raising an error. Binding the codes as text would pass the latter bar.
    func testFlagColorFilterFindsLilaRow() async {
        let lila = await search(["flag_color": .string("lila")])
        XCTAssertTrue(lila.ok, lila.message ?? "")
        XCTAssertEqual(lila.items.map(\.id), ["1"])
        XCTAssertEqual(lila.meta?["flag_color_codes"], "5")

        // The unmarked row with leftover code 5 must not come along: the filter always
        // combines flagged = 1 with the code.
        let byCode = await search(["flag_color": .string("5")])
        XCTAssertTrue(byCode.ok, byCode.message ?? "")
        XCTAssertEqual(byCode.items.map(\.id), ["1"])
    }

    func testFlagColorFilterListAndAliases() async {
        let list = await search(["flag_color": .string("lila, rot")])
        XCTAssertTrue(list.ok, list.message ?? "")
        XCTAssertEqual(Set(list.items.map(\.id)), ["1", "4"])
        XCTAssertEqual(list.meta?["flag_color_codes"], "0,5")

        let canonical = await search(["flag_color": .string("purple")])
        XCTAssertTrue(canonical.ok, canonical.message ?? "")
        XCTAssertEqual(Set(canonical.items.map(\.id)), ["1"])

        let german = await search(["flag_color": .string("rot")])
        XCTAssertTrue(german.ok, german.message ?? "")
        XCTAssertEqual(german.items.map(\.id), ["4"])
        XCTAssertEqual(german.meta?["flag_color_codes"], "0")
    }

    func testFlagColorFilterRejectsInvalidInput() async {
        let response = await search(["flag_color": .string("rosa")])
        XCTAssertFalse(response.ok)
        XCTAssertTrue(
            response.message?.contains("Mail flag_color must be one of") == true,
            response.message ?? ""
        )
    }

    /// A colour filter implies flagged = 1, and the metadata must say so. A caller reading
    /// flagged_only: false would otherwise have to assume unflagged messages could be present.
    func testFlagColorImpliesFlaggedOnlyInMetadata() async {
        let response = await search(["flag_color": .string("lila")])
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(response.meta?["flagged_only"], "true")
        XCTAssertEqual(response.meta?["flag_color_codes"], "5")
    }

    /// limit and offset must reach the SQL and come back in the metadata. Worth its own test
    /// because a client that serialises them as strings gets a type error instead, and from the
    /// response alone "rejected" and "silently ignored" look the same.
    func testLimitAndOffsetAreAppliedAndReported() async {
        let wide = await search(["limit": .number(50)])
        XCTAssertTrue(wide.ok, wide.message ?? "")
        XCTAssertEqual(wide.meta?["limit"], "50")
        let total = Int(wide.meta?["total"] ?? "0") ?? 0
        XCTAssertGreaterThan(total, 3, "the fixture must hold enough rows to page through")

        let first = await search(["limit": .number(2), "offset": .number(0)])
        XCTAssertEqual(first.meta?["limit"], "2")
        XCTAssertEqual(first.meta?["offset"], "0")
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(first.meta?["has_more"], "true")

        let second = await search(["limit": .number(2), "offset": .number(2)])
        XCTAssertEqual(second.meta?["offset"], "2")
        XCTAssertEqual(second.items.count, 2)
        XCTAssertTrue(
            Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)),
            "a second page must not repeat the first"
        )
    }

    /// Regression: separator-only input must produce the parse error, not a silent empty
    /// result by way of `IN ()`.
    func testFlagColorFilterRejectsSeparatorOnlyInput() async {
        for raw in [",", " , "] {
            let response = await search(["flag_color": .string(raw)])
            XCTAssertFalse(response.ok, "flag_color \(raw) must fail closed, not return nothing")
            XCTAssertTrue(
                response.message?.contains("Mail flag_color must be one of") == true,
                response.message ?? ""
            )
        }
    }

    func testMissingFlagColumnsFailClosed() async throws {
        let plain = try MailFixture(withFlagColumns: false)
        defer { plain.tearDown() }

        // Without a filter the search keeps working; the flag metadata is simply omitted.
        let unfiltered = await plain.withMailRoot {
            await MailProvider().search(input: [
                "query": .string("quarterly"),
                "fields": .array([.string("subject")])
            ])
        }
        XCTAssertTrue(unfiltered.ok, unfiltered.message ?? "")
        XCTAssertEqual(unfiltered.items.map(\.id), ["1"])
        XCTAssertNil(unfiltered.items.first?.metadata["flagged"])

        // With a filter requested the columns are missing, so a clear error is required,
        // not a silent fallback to an unfiltered search.
        let flaggedOnly = await plain.withMailRoot {
            await MailProvider().search(input: ["flagged_only": .bool(true)])
        }
        XCTAssertFalse(flaggedOnly.ok)
        XCTAssertTrue(
            flaggedOnly.message?.contains("Flag filtering is not available") == true,
            flaggedOnly.message ?? ""
        )

        let flagColor = await plain.withMailRoot {
            await MailProvider().search(input: ["flag_color": .string("lila")])
        }
        XCTAssertFalse(flagColor.ok)
        // Both columns are missing. The flagged guard fires first by construction; what matters
        // is that a clear MailStoreFailure message comes back, not which of the two produced it.
        XCTAssertTrue(
            flagColor.message?.contains("not available in this Mail index schema") == true,
            flagColor.message ?? ""
        )
    }

    func testUnknownCodeReportedAsUnknown() async {
        let response = await search([
            "query": .string("travel"),
            "fields": .array([.string("subject")])
        ])
        XCTAssertTrue(response.ok, response.message ?? "")
        XCTAssertEqual(response.items.map(\.id), ["3"])
        XCTAssertEqual(response.items.first?.metadata["flagged"], "true")
        XCTAssertEqual(response.items.first?.metadata["flag_color"], "7")
        XCTAssertEqual(response.items.first?.metadata["flag_color_name"], "unknown")
    }

    /// Exercises `MailFlagColor.resolve` through its only public entry point, the flag_color
    /// parameter of mail_search: valid tokens show up resolved in meta.flag_color_codes, invalid
    /// ones produce the parse message. Kept as a table so a rewrite cannot quietly narrow it.
    func testFlagColorResolveMatchesTheVerifiedVectorTable() async {
        let cases: [(token: String, expected: Int?)] = [
            ("red", 0), ("RED", 0), ("Rot", 0), ("rot", 0),
            ("orange", 1), ("ORANGE", 1),
            ("yellow", 2), ("gelb", 2), ("Gelb", 2),
            ("green", 3), ("grün", 3), ("GRÜN", 3), ("gruen", 3), ("Grün", 3),
            ("blue", 4), ("blau", 4),
            ("purple", 5), ("lila", 5), ("LILA", 5),
            ("gray", 6), ("grey", 6), ("grau", 6),
            ("0", 0), ("1", 1), ("2", 2), ("3", 3), ("4", 4), ("5", 5), ("6", 6),
            ("7", nil), ("8", nil), ("10", nil),
            ("05", nil), ("+5", nil), ("-1", nil),
            ("", nil),
            ("rosa", nil), ("pink", nil), ("redd", nil), ("5x", nil),
            ("\u{0665}", nil),
            ("gru\u{0308}n", 3)
        ]
        for (token, expected) in cases {
            let response = await search(["flag_color": .string(token)])
            if let expected {
                XCTAssertTrue(response.ok, "\(token): \(response.message ?? "")")
                XCTAssertEqual(response.meta?["flag_color_codes"], String(expected), token)
            } else if token.isEmpty {
                // Empty token means .none: no filter requested, no codes, no error.
                XCTAssertTrue(response.ok, "\(token): \(response.message ?? "")")
                XCTAssertEqual(response.meta?["flag_color_codes"], "", token)
            } else {
                XCTAssertFalse(response.ok, "\(token) must fail closed")
                XCTAssertTrue(
                    response.message?.contains("Mail flag_color must be one of") == true,
                    "\(token): \(response.message ?? "")"
                )
            }
        }
    }

    // MARK: - Reading one message

    func testReadingAMessageReturnsTheTextPartOfAMultipartBody() async {
        let response = await fixture.withMailRoot {
            await MailProvider().read(input: ["id": .string("11")])
        }

        XCTAssertTrue(response.ok, response.message ?? "")
        let item = try? XCTUnwrap(response.items.first)
        XCTAssertEqual(item?.title, "Multipart message")
        XCTAssertEqual(item?.metadata["mailbox_role"], "inbox")
        XCTAssertTrue(item?.preview?.contains("plain text part") == true, item?.preview ?? "")
        XCTAssertFalse(item?.preview?.contains("<b>") == true, "the HTML alternative must not win")
    }

    func testAMailboxPointingOutsideTheStoreDoesNotYieldAFileFromOutsideIt() async {
        let response = await fixture.withMailRoot {
            await MailProvider().read(input: ["id": .string("12")])
        }

        // The row is readable, because it is in the index. Its body is not, because the mailbox url
        // resolves outside the mail root and the .emlx candidate is rejected there.
        XCTAssertTrue(response.ok, response.message ?? "")
        let preview = response.items.first?.preview ?? ""
        XCTAssertFalse(
            preview.contains("secret-outside-the-store"),
            "a mailbox url that leaves the mail root must not read a file from outside it"
        )
    }

    func testANonNumericRowIdIsRefusedBeforeTheStoreIsOpened() async {
        for id in ["../../etc/passwd", "1; DROP TABLE messages", "01", "as:legacy"] {
            let response = await fixture.withMailRoot {
                await MailProvider().read(input: ["id": .string(id)])
            }
            XCTAssertFalse(response.ok, id)
        }
    }

    // MARK: - Mailbox descriptions

    func testMailboxUrlsAreSplitIntoAccountPathAndRole() {
        let imap = MailProvider.describeMailbox(
            url: "imap://alice%40example.test@mail.example.test/INBOX"
        )
        // The user component is percent-decoded, so an address-shaped user name produces an account
        // string with two '@'. Pinned as it is: this value is shown, never parsed again.
        XCTAssertEqual(imap.account, "alice@example.test@mail.example.test")
        XCTAssertEqual(imap.path, "INBOX")
        XCTAssertEqual(imap.name, "INBOX")
        XCTAssertEqual(imap.role, "inbox")

        let nested = MailProvider.describeMailbox(url: "Mailboxes/Archive/2019/Invoices")
        XCTAssertEqual(nested.account, "")
        XCTAssertEqual(nested.name, "Invoices")
        XCTAssertEqual(nested.path, "Mailboxes/Archive/2019/Invoices")
        XCTAssertEqual(nested.role, "folder", "only the leaf name decides the role")

        // German mailbox names are named roles too, which is what the junk and trash filters read.
        XCTAssertEqual(MailProvider.describeMailbox(url: "Mailboxes/Papierkorb").role, "trash")
        XCTAssertEqual(MailProvider.describeMailbox(url: "Mailboxes/Gesendet").role, "sent")
        XCTAssertEqual(MailProvider.describeMailbox(url: "Mailboxes/Werbung").role, "junk")

        let encoded = MailProvider.describeMailbox(url: "imap://mail.example.test/Gel%C3%B6schte%20Objekte")
        XCTAssertEqual(encoded.name, "Gelöschte Objekte")
        XCTAssertEqual(encoded.role, "trash")

        let empty = MailProvider.describeMailbox(url: "")
        XCTAssertEqual(empty.name, "")
        XCTAssertEqual(empty.role, "folder")
    }
}

/// A synthetic Mail store: an Envelope Index with the lookup-table schema, `.emlx` files on disk,
/// and one mailbox that deliberately points out of the store.
private final class MailFixture {
    let root: URL
    private let outside: URL

    init(withFlagColumns: Bool = true, withDateColumn: Bool = true) throws {
        let unique = UUID().uuidString
        root = URL(fileURLWithPath: "/private/tmp/m3mail-semantics-\(unique)", isDirectory: true)
        outside = URL(fileURLWithPath: "/private/tmp/m3mail-outside-\(unique)", isDirectory: true)

        let version = root.appendingPathComponent("V10", isDirectory: true)
        let mailData = version.appendingPathComponent("MailData", isDirectory: true)
        let inbox = version.appendingPathComponent("Mailboxes/Inbox/Messages", isDirectory: true)
        let archive = version.appendingPathComponent("Mailboxes/Archive/Messages", isDirectory: true)
        let outsideMessages = outside.appendingPathComponent("Messages", isDirectory: true)

        let manager = FileManager.default
        try manager.createDirectory(at: mailData, withIntermediateDirectories: true)
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try manager.createDirectory(at: archive, withIntermediateDirectories: true)
        try manager.createDirectory(at: outsideMessages, withIntermediateDirectories: true)

        // The escape route: a symlink inside the store pointing at a directory outside it.
        try manager.createSymbolicLink(
            at: version.appendingPathComponent("Mailboxes/Escape", isDirectory: true),
            withDestinationURL: outside
        )

        try Self.write(
            body: "secret-outside-the-store",
            to: outsideMessages.appendingPathComponent("12.emlx")
        )
        try Self.write(
            body: "bodyneedle appears only in the message body",
            to: inbox.appendingPathComponent("3.emlx")
        )
        try Self.writeMultipart(to: inbox.appendingPathComponent("11.emlx"))

        var database: OpaquePointer?
        guard sqlite3_open(mailData.appendingPathComponent("Envelope Index").path, &database) == SQLITE_OK,
              let database else {
            throw Self.error("could not create the synthetic Envelope Index")
        }
        defer { sqlite3_close(database) }
        try Self.populate(database, withFlagColumns: withFlagColumns, withDateColumn: withDateColumn)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    /// Redirects the provider's store location for the duration of one call.
    func withMailRoot<T>(_ operation: () async throws -> T) async rethrows -> T {
        let key = MailProvider.mailRootEnvironmentKey
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, root.path, 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        return try await operation()
    }

    private static func write(body: String, to url: URL) throws {
        let email = """
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(body)\r
        """
        try Data("\(email.utf8.count)\n\(email)".utf8).write(to: url)
    }

    private static func writeMultipart(to url: URL) throws {
        let email = """
        Content-Type: multipart/alternative; boundary="frontier"\r
        \r
        --frontier\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        This is the plain text part.\r
        --frontier\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><b>html part</b></body></html>\r
        --frontier--\r
        """
        try Data("\(email.utf8.count)\n\(email)".utf8).write(to: url)
    }

    private static func populate(_ database: OpaquePointer, withFlagColumns: Bool, withDateColumn: Bool) throws {
        let epochNow = Date().timeIntervalSince1970
        let referenceNow = Date().timeIntervalSinceReferenceDate

        // Fixed 2025/2026 dates for the date-range tests, resolved through Calendar so month
        // lengths and leap years are never computed by hand. Row 13 is deliberately stored in
        // the reference epoch, rows 14 and 15 in the Unix epoch.
        let calendar = Calendar.current
        let newYear2025 = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 12))!
        let lateEvening2025 = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 30))!
        let followingYear2026 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9))!

        try execute(
            """
            CREATE TABLE mailboxes (url TEXT, total_count INTEGER, unread_count INTEGER);
            INSERT INTO mailboxes (ROWID, url, total_count, unread_count) VALUES
                (1, 'Mailboxes/Inbox', 11, 4),
                (2, 'Mailboxes/Archive', 1, 0),
                (3, 'Mailboxes/Escape', 1, 0);

            CREATE TABLE subjects (subject TEXT);
            INSERT INTO subjects (ROWID, subject) VALUES
                (1, 'Quarterly invoice draft'),
                (2, 'Rechnung Q3'),
                (3, 'Travel plan'),
                (4, 'Weekly newsletter'),
                (5, 'Junk newsletter'),
                (6, 'Deleted newsletter'),
                (7, 'timestamp epoch recent'),
                (8, 'timestamp reference recent'),
                (9, 'timestamp epoch old'),
                (10, 'timestamp reference old'),
                (11, 'Multipart message'),
                (12, 'Message behind a symlink'),
                (13, 'New year memo'),
                (14, 'Late evening memo'),
                (15, 'Following year memo');

            CREATE TABLE addresses (address TEXT, comment TEXT);
            INSERT INTO addresses (ROWID, address, comment) VALUES
                (1, 'anna.beispiel@example.test', 'Anna Beispiel'),
                (2, 'bob@example.test', 'Bob'),
                (3, 'carla@example.test', NULL);
            """,
            on: database
        )

        var messageColumns = ["message_id TEXT", "subject INTEGER", "sender INTEGER"]
        if withDateColumn { messageColumns.append("date_received REAL") }
        messageColumns.append(contentsOf: ["read INTEGER", "deleted INTEGER", "junk INTEGER", "mailbox INTEGER"])
        if withFlagColumns {
            messageColumns.append(contentsOf: ["flagged INTEGER", "flags INTEGER"])
        }
        try execute(
            "CREATE TABLE messages (\n                "
                + messageColumns.joined(separator: ",\n                ")
                + "\n            );",
            on: database
        )

        try execute(
            """
            CREATE TABLE recipients (message INTEGER, address INTEGER);
            INSERT INTO recipients (message, address) VALUES (2, 3), (1, 2);
            """,
            on: database
        )

        // (rowid, flagged, flags), only populated when the flag columns exist.
        // Row 1: purple (code 5) and marked, the main case for the colour filter.
        // Row 2: leftover code 5 with flagged = 0, since Mail keeps the bits when unmarking.
        // Row 3: code 7, invalid, must be reported as unknown.
        // Row 4: red (code 0) and marked, for the list filter "purple, red".
        let flagRows: [Int: (flagged: Int, flags: Int)] = [
            1: (1, 5 << 39),
            2: (0, 5 << 39),
            3: (1, 7 << 39),
            4: (1, 0)
        ]

        // (rowid, subject, sender, date, read, deleted, junk, mailbox)
        let rows: [(Int, Int, Int, Double, Int, Int, Int, Int)] = [
            (1, 1, 1, epochNow - 60, 0, 0, 0, 1),
            (2, 2, 2, epochNow - 120, 0, 0, 0, 1),
            (3, 3, 2, epochNow - 180, 0, 0, 0, 1),
            (4, 4, 2, epochNow - 240, 1, 0, 0, 1),
            (5, 5, 2, epochNow - 300, 0, 0, 1, 1),
            (6, 6, 2, epochNow - 360, 0, 1, 0, 1),
            (7, 7, 2, epochNow - 600, 0, 0, 0, 1),
            (8, 8, 2, referenceNow - 900, 0, 0, 0, 1),
            (9, 9, 2, epochNow - 400_000, 0, 0, 0, 1),
            (10, 10, 2, referenceNow - 400_000, 0, 0, 0, 1),
            (11, 11, 2, epochNow - 700, 0, 0, 0, 1),
            (12, 12, 2, epochNow - 800, 0, 0, 0, 3),
            (13, 13, 2, newYear2025.timeIntervalSinceReferenceDate, 0, 0, 0, 1),
            (14, 14, 2, lateEvening2025.timeIntervalSince1970, 0, 0, 0, 1),
            (15, 15, 2, followingYear2026.timeIntervalSince1970, 0, 0, 0, 1)
        ]
        for (id, subject, sender, date, read, deleted, junk, mailbox) in rows {
            let flag: (flagged: Int, flags: Int) = withFlagColumns
                ? (flagRows[id] ?? (flagged: 0, flags: 0))
                : (flagged: 0, flags: 0)
            var columnList = "ROWID, message_id, subject, sender"
            var valueList = "(\(id), 'm\(id)', \(subject), \(sender)"
            if withDateColumn {
                columnList += ", date_received"
                valueList += ", \(date)"
            }
            columnList += ", read, deleted, junk, mailbox"
            valueList += ", \(read), \(deleted), \(junk), \(mailbox)"
            if withFlagColumns {
                columnList += ", flagged, flags"
                valueList += ", \(flag.flagged), \(flag.flags)"
            }
            try execute(
                "INSERT INTO messages (\(columnList)) VALUES \(valueList));",
                on: database
            )
        }
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw error(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "MailProviderSearchSemanticsTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
