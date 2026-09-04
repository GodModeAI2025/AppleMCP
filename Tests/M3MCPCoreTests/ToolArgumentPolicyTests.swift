import XCTest
@testable import M3MCPCore

final class ToolArgumentPolicyTests: XCTestCase {
    func testEveryPublicToolHasAClosedExhaustiveArgumentPolicy() {
        XCTAssertEqual(M3MCPToolName.allCases.count, 30)

        for tool in M3MCPToolName.allCases {
            let policy = M3MCPToolArgumentPolicy.forTool(tool)
            XCTAssertTrue(policy.requiredKeys.isSubset(of: policy.allowedKeys), tool.rawValue)
            XCTAssertTrue(Set(policy.integerRanges.keys).isSubset(of: policy.allowedKeys), tool.rawValue)
            for key in policy.integerRanges.keys {
                XCTAssertEqual(policy.argumentTypes[key], .integer, tool.rawValue)
            }
            for alternative in policy.requiredAlternativeKeySets {
                XCTAssertFalse(alternative.isEmpty, tool.rawValue)
                XCTAssertTrue(alternative.isSubset(of: policy.allowedKeys), tool.rawValue)
            }

            let error = policy.validationError(
                for: ["__not_advertised__": .string("smuggled")],
                tool: tool
            )
            XCTAssertNotNil(error, tool.rawValue)
            XCTAssertTrue(error?.clientMessage.contains("unknown key") == true, tool.rawValue)
        }
    }

    func testPolicyEnforcesRequiredAlternativeAndTopLevelTypes() {
        let createPolicy = M3MCPToolArgumentPolicy.forTool(.calendarCreateEvent)

        XCTAssertNotNil(createPolicy.validationError(
            for: [
                "title": .string("Review"),
                "start": .string("2026-09-04T10:00:00+02:00")
            ],
            tool: .calendarCreateEvent
        ))
        XCTAssertNil(createPolicy.validationError(
            for: [
                "title": .string("Review"),
                "start": .string("2026-09-04T10:00:00+02:00"),
                "calendar_id": .string("calendar-1"),
                "duration_minutes": .number(30),
                "all_day": .bool(false)
            ],
            tool: .calendarCreateEvent
        ))
        XCTAssertTrue(createPolicy.validationError(
            for: [
                "title": .string("Review"),
                "start": .string("2026-09-04T10:00:00+02:00"),
                "calendar_id": .string("calendar-1"),
                "duration_minutes": .number(30.5)
            ],
            tool: .calendarCreateEvent
        )?.clientMessage.contains("integer") == true)

        let mailPolicy = M3MCPToolArgumentPolicy.forTool(.mailSearch)
        XCTAssertNil(mailPolicy.validationError(
            for: ["fields": .array([.string("subject"), .string("body")])],
            tool: .mailSearch
        ))
        XCTAssertTrue(mailPolicy.validationError(
            for: ["fields": .array([.string("subject"), .number(1)])],
            tool: .mailSearch
        )?.clientMessage.contains("array of strings") == true)
    }

    func testVoiceMemoTimeoutRuntimeRangeMatchesAdvertisedContract() {
        let policy = M3MCPToolArgumentPolicy.forTool(.voiceMemosTranscribe)
        let minimum = VoiceMemoTranscriptionTimeoutPolicy.minimumSeconds
        let maximum = VoiceMemoTranscriptionTimeoutPolicy.maximumSeconds

        XCTAssertNil(policy.validationError(
            for: ["id": .string("1"), "timeout_seconds": .number(Double(minimum))],
            tool: .voiceMemosTranscribe
        ))
        XCTAssertNil(policy.validationError(
            for: ["id": .string("1"), "timeout_seconds": .number(Double(maximum))],
            tool: .voiceMemosTranscribe
        ))

        for value in [minimum - 1, maximum + 1] {
            let error = policy.validationError(
                for: ["id": .string("1"), "timeout_seconds": .number(Double(value))],
                tool: .voiceMemosTranscribe
            )
            XCTAssertTrue(error?.clientMessage.contains("between \(minimum) and \(maximum)") == true)
        }
    }

    func testIntegerArgumentsMustBeExactlyRepresentableAsSwiftInt() {
        let policy = M3MCPToolArgumentPolicy.forTool(.calendarUpdateEvent)

        for value in [Double.greatestFiniteMagnitude, 1e100, -1e100] {
            let error = policy.validationError(
                for: [
                    "id": .string("event-1"),
                    "duration_minutes": .number(value)
                ],
                tool: .calendarUpdateEvent
            )
            XCTAssertTrue(error?.clientMessage.contains("must be an integer") == true)
        }
    }

    func testValidationErrorBoundsAndEscapesAttackerControlledUnknownKeys() {
        var input: [String: JSONValue] = [:]
        for index in 0..<100 {
            input["padding_\(index)_\(String(repeating: "x", count: 200))\n"] = .string(
                String(repeating: "y", count: 1_000)
            )
        }

        let error = M3MCPToolArgumentPolicy
            .forTool(.sourceStatus)
            .validationError(for: input, tool: .sourceStatus)

        let message = error?.clientMessage ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertLessThanOrEqual(
            message.utf8.count,
            M3MCPToolArgumentValidationError.maximumClientMessageBytes
        )
        XCTAssertFalse(message.contains("\n"))
        XCTAssertTrue(message.contains("(+97 more)"))
    }
}
