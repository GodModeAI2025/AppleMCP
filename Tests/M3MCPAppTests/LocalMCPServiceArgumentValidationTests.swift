import XCTest
@testable import M3MCPApp
@testable import M3MCPCore

final class LocalMCPServiceArgumentValidationTests: XCTestCase {
    func testPaddingCannotHideCalendarOrShortcutFieldsFromApproval() async {
        let recorder = ApprovalRecorder()
        let service = LocalMCPService(
            securityPolicy: M3MCPSecurityPolicy(
                configuration: .init(
                    allowCalendarMutations: true,
                    allowUserShortcuts: true
                )
            ),
            approvalHandler: { request in
                await recorder.record(request)
                return true
            }
        )

        var calendarInput = paddedInput()
        calendarInput["calendar_id"] = .string("calendar-1")
        calendarInput["start"] = .string("2026-09-04T10:00:00+02:00")
        calendarInput["title"] = .string("Real calendar title")

        // The fair per-field preview still names the real mutation fields, while the independent
        // closed schema rejects attacker-controlled keys before any approval is presented.
        XCTAssertTrue(
            M3MCPInteractiveApproval.argumentPreview(calendarInput).contains("title:")
        )
        let calendarResponse = await service.handle(
            tool: M3MCPToolName.calendarCreateEvent.rawValue,
            input: calendarInput
        )
        assertArgumentRejection(calendarResponse)

        var shortcutInput = paddedInput()
        shortcutInput["action"] = .string("rewrite")
        shortcutInput["text"] = .string("Real Shortcut input")
        XCTAssertTrue(
            M3MCPInteractiveApproval.argumentPreview(shortcutInput).contains("text:")
        )
        let shortcutResponse = await service.handle(
            tool: M3MCPToolName.aiWritingTools.rawValue,
            input: shortcutInput
        )
        assertArgumentRejection(shortcutResponse)

        let approvalCount = await recorder.requestCount
        XCTAssertEqual(approvalCount, 0)
    }

    func testDirectLocalCallsEnforceRequiredKeysAndTypesBeforeApproval() async {
        let recorder = ApprovalRecorder()
        let service = LocalMCPService(
            securityPolicy: M3MCPSecurityPolicy(
                configuration: .init(allowCalendarMutations: true)
            ),
            approvalHandler: { request in
                await recorder.record(request)
                return true
            }
        )

        let missingTarget = await service.handle(
            tool: M3MCPToolName.calendarCreateEvent.rawValue,
            input: [
                "title": .string("Review"),
                "start": .string("2026-09-04T10:00:00+02:00")
            ]
        )
        assertArgumentRejection(missingTarget)
        XCTAssertTrue(missingTarget.message?.contains("requires") == true)

        let wrongType = await service.handle(
            tool: M3MCPToolName.calendarDeleteEvent.rawValue,
            input: ["id": .number(42)]
        )
        assertArgumentRejection(wrongType)
        XCTAssertTrue(wrongType.message?.contains("must be a string") == true)

        let approvalCount = await recorder.requestCount
        XCTAssertEqual(approvalCount, 0)
    }

    func testDirectLocalCallRejectsVoiceMemoTimeoutOutsideSchemaRange() async {
        let service = LocalMCPService()

        for value in [
            VoiceMemoTranscriptionTimeoutPolicy.minimumSeconds - 1,
            VoiceMemoTranscriptionTimeoutPolicy.maximumSeconds + 1
        ] {
            let response = await service.handle(
                tool: M3MCPToolName.voiceMemosTranscribe.rawValue,
                input: [
                    "id": .string("1"),
                    "timeout_seconds": .number(Double(value))
                ]
            )

            assertArgumentRejection(response)
            XCTAssertTrue(response.message?.contains("between 10 and 1800") == true)
        }
    }

    func testDirectLocalCallRejectsOutOfIntIntegerBeforeApproval() async {
        let recorder = ApprovalRecorder()
        let service = LocalMCPService(
            securityPolicy: M3MCPSecurityPolicy(
                configuration: .init(allowCalendarMutations: true)
            ),
            approvalHandler: { request in
                await recorder.record(request)
                return true
            }
        )

        let response = await service.handle(
            tool: M3MCPToolName.calendarUpdateEvent.rawValue,
            input: [
                "id": .string("event-1"),
                "title": .string("Still valid"),
                "duration_minutes": .number(1e100)
            ]
        )

        assertArgumentRejection(response)
        XCTAssertTrue(response.message?.contains("must be an integer") == true)
        let approvalCount = await recorder.requestCount
        XCTAssertEqual(approvalCount, 0)
    }

    private func paddedInput() -> [String: JSONValue] {
        var input: [String: JSONValue] = [:]
        for index in 0..<40 {
            let key = String(format: "000_padding_%03d_", index)
                + String(repeating: "p", count: M3MCPInteractiveApproval.maximumKeyCharacters)
            input[key] = .string(
                String(repeating: "x", count: M3MCPInteractiveApproval.maximumScalarCharacters)
            )
        }
        return input
    }

    private func assertArgumentRejection(
        _ response: ToolResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(response.ok, file: file, line: line)
        XCTAssertEqual(response.source, "M3MCP Argument Validation", file: file, line: line)
        XCTAssertTrue(response.message?.contains("unknown key") == true ||
            response.message?.contains("Invalid arguments") == true, file: file, line: line)
        XCTAssertLessThanOrEqual(
            response.message?.utf8.count ?? Int.max,
            M3MCPToolArgumentValidationError.maximumClientMessageBytes,
            file: file,
            line: line
        )
    }
}

private actor ApprovalRecorder {
    private(set) var requestCount = 0

    func record(_ request: M3MCPToolApprovalRequest) {
        _ = request
        requestCount += 1
    }
}
