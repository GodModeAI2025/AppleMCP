import XCTest
@testable import M3MCPCore

final class InteractiveApprovalTests: XCTestCase {
    func testOnlyCalendarMutationsAndUserShortcutsRequireInteractiveApproval() {
        let expected: Set<M3MCPToolName> = [
            .calendarCreateEvent,
            .calendarUpdateEvent,
            .calendarDeleteEvent,
            .calendarCreateCalendar,
            .calendarDeleteCalendar,
            .calendarUndoWrite,
            .aiWritingTools,
            .aiTranslate
        ]

        XCTAssertEqual(
            Set(M3MCPToolName.allCases.filter(M3MCPInteractiveApproval.requiresApproval)),
            expected
        )

        XCTAssertFalse(M3MCPInteractiveApproval.requiresApproval(for: .permissionsRequest))
        XCTAssertFalse(M3MCPInteractiveApproval.requiresApproval(for: .permissionsOpenSettings))
    }

    func testLaunchOptInDoesNotRemovePerCallApprovalRequirement() {
        let optedIn = M3MCPSecurityPolicy(
            configuration: .init(
                allowCalendarMutations: true,
                allowPermissionUI: true,
                allowUserShortcuts: true
            )
        )

        for tool in [
            M3MCPToolName.calendarCreateEvent,
            .calendarUpdateEvent,
            .calendarDeleteEvent,
            .calendarCreateCalendar,
            .calendarDeleteCalendar,
            .calendarUndoWrite,
            .aiWritingTools,
            .aiTranslate
        ] {
            XCTAssertTrue(optedIn.allows(tool), "Launch policy should expose \(tool.rawValue)")
            XCTAssertTrue(
                M3MCPInteractiveApproval.requiresApproval(for: tool),
                "Opt-in must not bypass per-call approval for \(tool.rawValue)"
            )
        }

        XCTAssertTrue(optedIn.allows(.permissionsRequest))
        XCTAssertFalse(M3MCPInteractiveApproval.requiresApproval(for: .permissionsRequest))
    }

    /// The dry-run exemption is the one way past the sheet, so it is pinned from both sides: it must
    /// hold for every write tool that declares `dry_run`, and it must not be reachable by any other
    /// shape of the argument or by a tool that never learned to preview.
    func testOnlyAnExplicitBooleanDryRunSkipsTheApprovalSheet() {
        let previewable: [M3MCPToolName] = [
            .calendarCreateEvent,
            .calendarUpdateEvent,
            .calendarDeleteEvent,
            .calendarCreateCalendar,
            .calendarDeleteCalendar,
            .calendarUndoWrite
        ]

        for tool in previewable {
            XCTAssertTrue(
                M3MCPToolArgumentPolicy.forTool(tool).allowedKeys.contains("dry_run"),
                "\(tool.rawValue) must advertise the parameter its exemption depends on"
            )
            XCTAssertFalse(
                M3MCPInteractiveApproval.requiresApproval(for: tool, input: ["dry_run": .bool(true)]),
                "a preview of \(tool.rawValue) writes nothing and has nothing to approve"
            )

            for commitShape: [String: JSONValue] in [
                [:],
                ["dry_run": .bool(false)],
                ["dry_run": .string("true")],
                ["dry_run": .number(1)],
                ["dry_run": .null]
            ] {
                XCTAssertTrue(
                    M3MCPInteractiveApproval.requiresApproval(for: tool, input: commitShape),
                    "\(tool.rawValue) must keep its sheet for \(commitShape)"
                )
            }
        }

        // A tool with no dry-run contract cannot be talked out of its sheet by the key alone.
        for tool in [M3MCPToolName.aiWritingTools, .aiTranslate] {
            XCTAssertFalse(M3MCPToolArgumentPolicy.forTool(tool).allowedKeys.contains("dry_run"))
            XCTAssertTrue(
                M3MCPInteractiveApproval.requiresApproval(for: tool, input: ["dry_run": .bool(true)])
            )
        }

        // And a read stays free of the sheet either way.
        XCTAssertFalse(M3MCPInteractiveApproval.requiresApproval(for: .calendarSearch, input: [:]))
    }

    func testWriteIntentDefaultsToCommitForEveryNonBooleanShape() {
        XCTAssertEqual(M3MCPWriteIntent.resolve(from: ["dry_run": .bool(true)]), .dryRun)
        XCTAssertEqual(M3MCPWriteIntent.resolve(from: [:]), .commit)
        XCTAssertEqual(M3MCPWriteIntent.resolve(from: ["dry_run": .bool(false)]), .commit)
        XCTAssertEqual(M3MCPWriteIntent.resolve(from: ["dry_run": .string("true")]), .commit)
        XCTAssertEqual(M3MCPWriteIntent.resolve(from: ["dry_run": .number(1)]), .commit)
        XCTAssertEqual(M3MCPWriteIntent.resolve(from: ["dry_run": .null]), .commit)

        XCTAssertTrue(M3MCPWriteIntent.commit.writes)
        XCTAssertFalse(M3MCPWriteIntent.dryRun.writes)
        XCTAssertEqual(M3MCPWriteIntent.dryRun.metaValue, "true")
        XCTAssertEqual(M3MCPWriteIntent.commit.metaValue, "false")
    }

    func testPreviewIsStableSortedAndEscapesControls() {
        let input: [String: JSONValue] = [
            "z": .string("line 1\nline 2\u{202E}"),
            "a": .object([
                "second": .number(2),
                "first": .bool(true)
            ])
        ]

        XCTAssertEqual(
            M3MCPInteractiveApproval.argumentPreview(input),
            "a: {\"first\": true, \"second\": 2.0}\nz: \"line 1\\nline 2\\u{202E}\""
        )
    }

    func testPreviewRedactsCredentialLikeValuesAtEveryObjectLevel() {
        let input: [String: JSONValue] = [
            "api_key": .string("top-secret"),
            "nested": .object([
                "authorization": .string("Bearer private"),
                "ordinary": .string("visible")
            ]),
            "sessionToken": .array([.string("one"), .string("two")])
        ]

        let preview = M3MCPInteractiveApproval.argumentPreview(input)

        XCTAssertEqual(
            preview,
            "api_key: [REDACTED]\nnested: {\"authorization\": [REDACTED], \"ordinary\": \"visible\"}\nsessionToken: [REDACTED]"
        )
        XCTAssertFalse(preview.contains("top-secret"))
        XCTAssertFalse(preview.contains("Bearer private"))
    }

    func testPreviewBoundsIndividualScalarsAndWholeOutput() {
        let longValue = String(repeating: "x", count: 1_000)
        let scalarPreview = M3MCPInteractiveApproval.argumentPreview(["text": .string(longValue)])
        XCTAssertLessThanOrEqual(scalarPreview.count, 250)
        XCTAssertTrue(scalarPreview.hasSuffix("…\""))

        let bounded = M3MCPInteractiveApproval.argumentPreview(
            [
                "a": .string(longValue),
                "b": .string(longValue),
                "c": .string(longValue)
            ],
            maximumCharacters: 100
        )
        XCTAssertEqual(bounded.count, 100)
        XCTAssertTrue(bounded.hasSuffix("…"))
    }

    func testPreviewNamesEveryAllowedCalendarUpdateFieldDespiteLongValues() {
        let policy = M3MCPToolArgumentPolicy.forTool(.calendarUpdateEvent)
        var input: [String: JSONValue] = [:]

        for (key, type) in policy.argumentTypes {
            switch type {
            case .string:
                input[key] = .string(String(repeating: "x", count: 2_000))
            case .integer:
                input[key] = .number(120)
            case .boolean:
                input[key] = .bool(true)
            case .stringArray:
                input[key] = .array([.string(String(repeating: "x", count: 2_000))])
            }
        }

        let preview = M3MCPInteractiveApproval.argumentPreview(input)
        let shownKeys = Set(preview.split(separator: "\n").compactMap { line in
            line.split(separator: ":", maxSplits: 1).first.map(String.init)
        })

        XCTAssertEqual(shownKeys, policy.allowedKeys)
        XCTAssertLessThanOrEqual(
            preview.count,
            M3MCPInteractiveApproval.defaultMaximumPreviewCharacters
        )
        for criticalKey in ["id", "start", "title", "span", "calendar", "calendar_id"] {
            XCTAssertTrue(shownKeys.contains(criticalKey))
        }
    }

    func testRequestContainsToolAndPreviewButNoReusableDecisionState() {
        let request = M3MCPToolApprovalRequest(
            tool: .calendarDeleteEvent,
            input: ["id": .string("event-123")]
        )

        XCTAssertEqual(request.tool, .calendarDeleteEvent)
        XCTAssertEqual(request.argumentPreview, "id: \"event-123\"")
    }
}
