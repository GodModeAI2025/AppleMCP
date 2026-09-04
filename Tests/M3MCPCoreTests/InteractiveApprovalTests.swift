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
