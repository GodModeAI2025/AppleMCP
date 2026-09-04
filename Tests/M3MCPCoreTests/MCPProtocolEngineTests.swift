import XCTest
@testable import M3MCPCore

final class MCPProtocolEngineTests: XCTestCase {
    private let allowedTools: Set<String> = [
        M3MCPToolName.sourceStatus.rawValue,
        M3MCPToolName.mailSearch.rawValue
    ]

    func testNegotiatesEveryExplicitlySupportedRevisionAndGatesFeatures() throws {
        for revision in M3MCPProtocolRevision.allCases {
            var engine = M3MCPProtocolEngine(allowedToolNames: allowedTools)
            let initialization = engine.process(try initializeRequest(version: revision.rawValue))

            XCTAssertEqual(
                resultObject(initialization)?["protocolVersion"],
                .string(revision.rawValue),
                revision.rawValue
            )
            XCTAssertEqual(engine.phase, .awaitingInitialized(revision))

            XCTAssertEqual(
                engine.process(try notification("notifications/initialized")),
                .noResponse
            )
            XCTAssertEqual(engine.phase, .ready(revision))

            let list = engine.process(try request(id: 2, method: "tools/list"))
            XCTAssertEqual(
                list,
                .listTools(id: .integer(2), includeAnnotations: revision.supportsToolAnnotations)
            )

            let call = engine.process(try request(
                id: 3,
                method: "tools/call",
                params: ["name": M3MCPToolName.sourceStatus.rawValue]
            ))
            XCTAssertEqual(
                call,
                .callTool(
                    id: .integer(3),
                    name: M3MCPToolName.sourceStatus.rawValue,
                    arguments: [:],
                    includeStructuredContent: revision.supportsStructuredToolResults
                )
            )
        }
    }

    func testUnsupportedRevisionOffersNewestVerifiedRevision() throws {
        var engine = M3MCPProtocolEngine(allowedToolNames: allowedTools)
        let output = engine.process(try initializeRequest(version: "2026-07-28"))

        XCTAssertEqual(
            resultObject(output)?["protocolVersion"],
            .string(M3MCPProtocolRevision.newestSupported.rawValue)
        )
        XCTAssertEqual(engine.phase, .awaitingInitialized(.newestSupported))
    }

    func testRequiresCompleteInitializationBeforeToolsCanRun() throws {
        var engine = M3MCPProtocolEngine(allowedToolNames: allowedTools)

        assertError(
            engine.process(try request(id: 1, method: "tools/list")),
            id: .integer(1),
            code: -32002
        )
        assertError(
            engine.process(try request(
                id: 2,
                method: "tools/call",
                params: ["name": M3MCPToolName.sourceStatus.rawValue]
            )),
            id: .integer(2),
            code: -32002
        )

        _ = engine.process(try initializeRequest(version: "2025-11-25"))
        XCTAssertEqual(engine.phase, .awaitingInitialized(.v2025_11_25))
        assertError(
            engine.process(try request(id: 3, method: "tools/list")),
            id: .integer(3),
            code: -32002
        )

        assertError(
            engine.process(try request(id: 4, method: "notifications/initialized")),
            id: .integer(4),
            code: -32600
        )
        XCTAssertEqual(engine.phase, .awaitingInitialized(.v2025_11_25))

        XCTAssertEqual(
            engine.process(try notification("notifications/initialized")),
            .noResponse
        )
        XCTAssertEqual(engine.phase, .ready(.v2025_11_25))

        assertError(
            engine.process(try initializeRequest(version: "2025-11-25", id: 5)),
            id: .integer(5),
            code: -32600
        )
    }

    func testValidNotificationsNeverReceiveResponsesOrInvokeTools() throws {
        var engine = M3MCPProtocolEngine(allowedToolNames: allowedTools)

        XCTAssertEqual(engine.process(try notification("unknown/event")), .noResponse)
        XCTAssertEqual(
            engine.process(try notification(
                "tools/call",
                params: ["name": M3MCPToolName.sourceStatus.rawValue, "arguments": [:]]
            )),
            .noResponse
        )

        let invalidParamsNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [1, 2, 3]
        ]
        XCTAssertEqual(engine.process(try json(invalidParamsNotification)), .noResponse)
        XCTAssertEqual(engine.phase, .uninitialized)
    }

    func testCancellationNotificationProducesAnInternalActionWithoutAResponse() throws {
        var engine = M3MCPProtocolEngine(allowedToolNames: allowedTools)

        XCTAssertEqual(
            engine.process(try notification(
                "notifications/cancelled",
                params: ["requestId": 42, "reason": "user stopped"]
            )),
            .cancelRequest(id: .integer(42))
        )
        XCTAssertEqual(
            engine.process(try notification(
                "notifications/cancelled",
                params: ["requestId": "long-call"]
            )),
            .cancelRequest(id: .string("long-call"))
        )

        for invalidParams: [String: Any]? in [
            nil,
            [:],
            ["requestId": NSNull()],
            ["requestId": true],
            ["requestId": 1.5],
            ["requestId": 1, "reason": 99],
            ["requestId": 1, "reason": String(repeating: "x", count: 257)]
        ] {
            XCTAssertEqual(
                engine.process(try notification(
                    "notifications/cancelled",
                    params: invalidParams
                )),
                .noResponse
            )
        }

        assertError(
            engine.process(try request(
                id: 9,
                method: "notifications/cancelled",
                params: ["requestId": 42]
            )),
            id: .integer(9),
            code: -32600
        )
    }

    func testStrictJSONRPCEnvelopeValidationAndBoundedErrors() throws {
        var engine = M3MCPProtocolEngine(allowedToolNames: allowedTools)

        assertError(engine.process(Data("{".utf8)), id: nil, code: -32700)
        assertError(engine.process(try json([])), id: nil, code: -32600)
        assertError(engine.process(try json("fragment")), id: nil, code: -32600)
        assertError(
            engine.process(try json(["jsonrpc": "1.0", "id": 1, "method": "ping"])),
            id: nil,
            code: -32600
        )
        assertError(
            engine.process(try json(["jsonrpc": "2.0", "id": NSNull(), "method": "ping"])),
            id: nil,
            code: -32600
        )
        assertError(
            engine.process(try json(["jsonrpc": "2.0", "id": true, "method": "ping"])),
            id: nil,
            code: -32600
        )
        assertError(
            engine.process(try json(["jsonrpc": "2.0", "id": 1.5, "method": "ping"])),
            id: nil,
            code: -32600
        )
        assertError(
            engine.process(try json([
                "jsonrpc": "2.0",
                "id": String(repeating: "x", count: 257),
                "method": "ping"
            ])),
            id: nil,
            code: -32600
        )
        assertError(
            engine.process(try json([
                "jsonrpc": "2.0",
                "id": 8,
                "method": "ping",
                "params": ["not", "an", "object"]
            ])),
            id: .integer(8),
            code: -32602
        )

        // A server must not respond to a response, even though this bridge never sends requests.
        XCTAssertEqual(
            engine.process(try json(["jsonrpc": "2.0", "id": 9, "result": [:]])),
            .noResponse
        )

        var tinyEngine = M3MCPProtocolEngine(allowedToolNames: [], maximumMessageBytes: 8)
        assertError(
            tinyEngine.process(Data(repeating: 0x20, count: 9)),
            id: nil,
            code: -32700
        )
    }

    func testRejectsOverlyDeepJSONBeforeDispatch() throws {
        var nested: Any = "leaf"
        for _ in 0..<40 {
            nested = ["next": nested]
        }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "ping",
            "params": ["nested": nested]
        ]
        var engine = M3MCPProtocolEngine(allowedToolNames: allowedTools)
        assertError(engine.process(try json(envelope)), id: nil, code: -32600)
    }

    func testInitializeRequiresCompleteTypedParams() throws {
        let malformed: [[String: Any]?] = [
            nil,
            [:],
            ["protocolVersion": "2025-11-25"],
            [
                "protocolVersion": "2025-11-25",
                "capabilities": [],
                "clientInfo": ["name": "test", "version": "1"]
            ],
            [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "", "version": "1"]
            ]
        ]

        for (index, params) in malformed.enumerated() {
            var engine = M3MCPProtocolEngine(allowedToolNames: allowedTools)
            assertError(
                engine.process(try request(id: index, method: "initialize", params: params)),
                id: .integer(Int64(index)),
                code: -32602
            )
            XCTAssertEqual(engine.phase, .uninitialized)
        }
    }

    func testRejectsUnknownDisabledToolsAndNonObjectArgumentsWithoutDispatch() throws {
        var engine = try readyEngine(version: "2025-11-25")

        assertError(
            engine.process(try request(
                id: 1,
                method: "tools/call",
                params: ["name": "not_in_catalog"]
            )),
            id: .integer(1),
            code: -32602
        )
        assertError(
            engine.process(try request(
                id: 2,
                method: "tools/call",
                params: [
                    "name": M3MCPToolName.sourceStatus.rawValue,
                    "arguments": [1, 2]
                ]
            )),
            id: .integer(2),
            code: -32602
        )
        assertError(
            engine.process(try request(
                id: 3,
                method: "tools/call",
                params: ["name": 42]
            )),
            id: .integer(3),
            code: -32602
        )
    }

    func testBridgeRejectsOutOfIntIntegerArgumentBeforeDispatch() throws {
        var engine = M3MCPProtocolEngine(
            allowedToolNames: [M3MCPToolName.calendarUpdateEvent.rawValue]
        )
        _ = engine.process(try initializeRequest(version: "2025-11-25"))
        _ = engine.process(try notification("notifications/initialized"))

        let disposition = engine.process(try request(
            id: 991,
            method: "tools/call",
            params: [
                "name": M3MCPToolName.calendarUpdateEvent.rawValue,
                "arguments": [
                    "id": "event-1",
                    "title": "Still valid",
                    "duration_minutes": 1e100
                ]
            ]
        ))

        assertError(
            disposition,
            id: .integer(991),
            code: -32602,
            messageContains: "must be an integer"
        )
    }

    func testRejectsUnknownKeysWrongTypesAndMissingRequiredArgumentsBeforeDispatch() throws {
        var engine = try readyEngine(
            version: "2025-11-25",
            allowedToolNames: [M3MCPToolName.calendarCreateEvent.rawValue]
        )

        assertError(
            engine.process(try request(
                id: 20,
                method: "tools/call",
                params: [
                    "name": M3MCPToolName.calendarCreateEvent.rawValue,
                    "arguments": [
                        "title": "Review",
                        "start": "2026-09-04T10:00:00+02:00",
                        "calendar_id": "calendar-1",
                        "shadow_title": "Hidden replacement"
                    ]
                ]
            )),
            id: .integer(20),
            code: -32602,
            messageContains: "unknown key"
        )

        assertError(
            engine.process(try request(
                id: 21,
                method: "tools/call",
                params: [
                    "name": M3MCPToolName.calendarCreateEvent.rawValue,
                    "arguments": [
                        "title": true,
                        "start": "2026-09-04T10:00:00+02:00",
                        "calendar_id": "calendar-1"
                    ]
                ]
            )),
            id: .integer(21),
            code: -32602,
            messageContains: "must be a string"
        )

        assertError(
            engine.process(try request(
                id: 22,
                method: "tools/call",
                params: [
                    "name": M3MCPToolName.calendarCreateEvent.rawValue,
                    "arguments": [
                        "title": "Review",
                        "start": "2026-09-04T10:00:00+02:00"
                    ]
                ]
            )),
            id: .integer(22),
            code: -32602,
            messageContains: "requires"
        )

        assertError(
            engine.process(try request(
                id: 23,
                method: "tools/call",
                params: [
                    "name": M3MCPToolName.calendarCreateEvent.rawValue,
                    "arguments": ["calendar_id": "calendar-1"]
                ]
            )),
            id: .integer(23),
            code: -32602,
            messageContains: "missing required"
        )
    }

    func testUnknownArgumentProtocolErrorIsBoundedAndUseful() throws {
        var arguments: [String: Any] = [:]
        for index in 0..<100 {
            arguments["000_padding_\(index)_\(String(repeating: "x", count: 200))"] = String(
                repeating: "y",
                count: 1_000
            )
        }
        var engine = try readyEngine(version: "2025-11-25")

        assertError(
            engine.process(try request(
                id: 24,
                method: "tools/call",
                params: [
                    "name": M3MCPToolName.sourceStatus.rawValue,
                    "arguments": arguments
                ]
            )),
            id: .integer(24),
            code: -32602,
            messageContains: "(+97 more)"
        )
    }

    func testPreservesTypedToolArguments() throws {
        var engine = try readyEngine(version: "2025-06-18")
        let output = engine.process(try request(
            id: 12,
            method: "tools/call",
            params: [
                "name": M3MCPToolName.mailSearch.rawValue,
                "arguments": [
                    "query": "hello",
                    "limit": 3,
                    "unread_only": true,
                    "fields": ["subject", "body"]
                ]
            ]
        ))

        XCTAssertEqual(
            output,
            .callTool(
                id: .integer(12),
                name: M3MCPToolName.mailSearch.rawValue,
                arguments: [
                    "query": .string("hello"),
                    "limit": .number(3),
                    "unread_only": .bool(true),
                    "fields": .array([.string("subject"), .string("body")])
                ],
                includeStructuredContent: true
            )
        )
    }

    func testToolListRejectsUnsupportedCursor() throws {
        var engine = try readyEngine(version: "2025-11-25")
        assertError(
            engine.process(try request(
                id: "page",
                method: "tools/list",
                params: ["cursor": "unexpected"]
            )),
            id: .string("page"),
            code: -32602
        )
    }

    func testToolSecurityHintsAreExplicitAndConservative() {
        for tool in M3MCPToolName.allCases {
            _ = M3MCPToolSecurityHints.forTool(tool)
        }

        XCTAssertEqual(
            M3MCPToolSecurityHints.forTool(.calendarSearch),
            M3MCPToolSecurityHints(
                readOnly: true,
                destructive: false,
                idempotent: true,
                openWorld: false
            )
        )
        XCTAssertEqual(
            M3MCPToolSecurityHints.forTool(.calendarCreateEvent),
            M3MCPToolSecurityHints(
                readOnly: false,
                destructive: false,
                idempotent: false,
                openWorld: true
            )
        )
        XCTAssertTrue(M3MCPToolSecurityHints.forTool(.calendarDeleteCalendar).destructive)
        XCTAssertTrue(M3MCPToolSecurityHints.forTool(.calendarDeleteCalendar).idempotent)
        XCTAssertEqual(
            M3MCPToolSecurityHints.forTool(.aiTranslate),
            M3MCPToolSecurityHints(
                readOnly: false,
                destructive: true,
                idempotent: false,
                openWorld: true
            )
        )
    }

    // MARK: - Helpers

    private func readyEngine(
        version: String,
        allowedToolNames override: Set<String>? = nil
    ) throws -> M3MCPProtocolEngine {
        var engine = M3MCPProtocolEngine(allowedToolNames: override ?? allowedTools)
        _ = engine.process(try initializeRequest(version: version))
        _ = engine.process(try notification("notifications/initialized"))
        return engine
    }

    private func initializeRequest(version: String, id: Any = 1) throws -> Data {
        try request(
            id: id,
            method: "initialize",
            params: [
                "protocolVersion": version,
                "capabilities": [:],
                "clientInfo": ["name": "MCPProtocolEngineTests", "version": "1.0"]
            ]
        )
    }

    private func request(
        id: Any,
        method: String,
        params: [String: Any]? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        object["params"] = params
        return try json(object)
    }

    private func notification(
        _ method: String,
        params: [String: Any]? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        object["params"] = params
        return try json(object)
    }

    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    private func resultObject(_ output: M3MCPProtocolDisposition) -> [String: JSONValue]? {
        guard case .response(let response) = output,
              case .result(.object(let result)) = response.payload
        else { return nil }
        return result
    }

    private func assertError(
        _ output: M3MCPProtocolDisposition,
        id expectedID: M3MCPRequestID?,
        code expectedCode: Int,
        messageContains expectedMessageFragment: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .response(let response) = output,
              case .error(let code, let message) = response.payload
        else {
            return XCTFail("Expected JSON-RPC error, got \(output)", file: file, line: line)
        }
        XCTAssertEqual(response.id, expectedID, file: file, line: line)
        XCTAssertEqual(code, expectedCode, file: file, line: line)
        XCTAssertLessThan(message.utf8.count, 256, file: file, line: line)
        if let expectedMessageFragment {
            XCTAssertTrue(
                message.contains(expectedMessageFragment),
                "Expected error message to contain '\(expectedMessageFragment)', got '\(message)'",
                file: file,
                line: line
            )
        }
    }
}
