import Darwin
import Foundation
import XCTest
@testable import M3MCPBridge
@testable import M3MCPCore

final class MCPServerFormattingTests: XCTestCase {
    func testAnnotationsAreOnlyEmittedWhenNegotiated() throws {
        let tool = try XCTUnwrap(ToolCatalog.tools.first)

        let legacy = MCPServer.makeToolObject(tool, includeAnnotations: false)
        XCTAssertNil(legacy["annotations"])

        let current = MCPServer.makeToolObject(tool, includeAnnotations: true)
        let annotations = try XCTUnwrap(current["annotations"] as? [String: Bool])
        XCTAssertEqual(annotations["readOnlyHint"], tool.securityHints.readOnly)
        XCTAssertEqual(annotations["destructiveHint"], tool.securityHints.destructive)
        XCTAssertEqual(annotations["idempotentHint"], tool.securityHints.idempotent)
        XCTAssertEqual(annotations["openWorldHint"], tool.securityHints.openWorld)
    }

    func testDefaultCatalogContainsOnlyLaunchPolicyAllowedTools() {
        let policy = M3MCPSecurityPolicy.fromProcessEnvironment()
        XCTAssertEqual(
            Set(ToolCatalog.tools.map(\.name)),
            Set(M3MCPToolName.allCases.filter(policy.allows).map(\.rawValue))
        )
        XCTAssertFalse(ToolCatalog.tools.contains { $0.name == M3MCPToolName.calendarDeleteCalendar.rawValue })
        XCTAssertFalse(ToolCatalog.tools.contains { $0.name == M3MCPToolName.aiTranslate.rawValue })
    }

    func testCompleteCatalogIsUniqueAndMatchesReviewedCoreVocabulary() {
        let names = ToolCatalog.allTools.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertEqual(Set(names), M3MCPSecurityPolicy.knownToolNames)

        for tool in ToolCatalog.allTools {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool.schema), tool.name)
            XCTAssertTrue(tool.declaredSchemaMatchesArgumentPolicy, tool.name)

            let toolName = try? XCTUnwrap(M3MCPToolName(rawValue: tool.name))
            guard let toolName else { continue }
            let policy = M3MCPToolArgumentPolicy.forTool(toolName)
            let properties = tool.schema["properties"] as? [String: Any]
            XCTAssertEqual(Set(properties?.keys.map { $0 } ?? []), policy.allowedKeys, tool.name)
            XCTAssertEqual(tool.schema["additionalProperties"] as? Bool, false, tool.name)

            for (key, expectedType) in policy.argumentTypes {
                let property = properties?[key] as? [String: Any]
                XCTAssertEqual(
                    property?["type"] as? String,
                    expectedType.jsonSchemaType,
                    "\(tool.name).\(key)"
                )
                if let expectedItemType = expectedType.jsonSchemaItemType {
                    let items = property?["items"] as? [String: Any]
                    XCTAssertEqual(
                        items?["type"] as? String,
                        expectedItemType,
                        "\(tool.name).\(key)"
                    )
                }
            }

            XCTAssertEqual(
                Set(tool.schema["required"] as? [String] ?? []),
                policy.requiredKeys,
                tool.name
            )
            let alternatives = (tool.schema["anyOf"] as? [[String: Any]] ?? []).map { branch in
                Set(branch["required"] as? [String] ?? [])
            }
            XCTAssertEqual(alternatives, policy.requiredAlternativeKeySets, tool.name)
        }
    }

    func testVoiceMemoTimeoutSchemaUsesSharedProviderBounds() throws {
        let tool = try XCTUnwrap(
            ToolCatalog.allTools.first { $0.name == M3MCPToolName.voiceMemosTranscribe.rawValue }
        )
        let properties = try XCTUnwrap(tool.schema["properties"] as? [String: Any])
        let timeout = try XCTUnwrap(properties["timeout_seconds"] as? [String: Any])

        XCTAssertEqual(
            timeout["minimum"] as? Int,
            VoiceMemoTranscriptionTimeoutPolicy.minimumSeconds
        )
        XCTAssertEqual(
            timeout["maximum"] as? Int,
            VoiceMemoTranscriptionTimeoutPolicy.maximumSeconds
        )
    }

    func testStructuredContentMirrorsTextJSONOnlyWhenNegotiated() throws {
        let providerResponse = ToolResponse(
            ok: true,
            source: "test-provider",
            items: [
                DataItem(
                    id: "item-1",
                    title: "Example",
                    kind: "test",
                    source: "fixture",
                    metadata: ["bounded": "true"]
                )
            ],
            message: "done",
            meta: ["total": "1"]
        )

        let legacy = MCPServer.makeToolResultObject(
            id: .integer(1),
            response: providerResponse,
            includeStructuredContent: false
        )
        let legacyResult = try resultObject(legacy)
        XCTAssertNil(legacyResult["structuredContent"])
        XCTAssertNotNil(textContent(in: legacyResult))

        let current = MCPServer.makeToolResultObject(
            id: .string("call"),
            response: providerResponse,
            includeStructuredContent: true
        )
        let currentResult = try resultObject(current)
        let structured = try XCTUnwrap(currentResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["ok"] as? Bool, true)
        XCTAssertEqual(structured["source"] as? String, "test-provider")
        XCTAssertEqual(structured["message"] as? String, "done")
        XCTAssertNotNil(textContent(in: currentResult))
    }

    func testLargeResultIsNotDuplicatedAsStructuredContent() throws {
        let marker = String(repeating: "a", count: MCPServer.maximumStructuredContentBytes + 1)
        let providerResponse = ToolResponse(
            ok: true,
            source: "fixture",
            items: [
                DataItem(
                    id: "large",
                    title: "Large bounded fixture",
                    kind: "test",
                    source: "fixture",
                    preview: marker
                )
            ]
        )

        let object = MCPServer.makeToolResultObject(
            id: .integer(2),
            response: providerResponse,
            includeStructuredContent: true
        )
        let result = try resultObject(object)
        XCTAssertNil(result["structuredContent"])
        let text = try XCTUnwrap(textContent(in: result))
        XCTAssertTrue(text.contains(marker))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testProviderFailureRemainsAToolResultInsteadOfProtocolError() throws {
        let object = MCPServer.makeToolResultObject(
            id: .integer(7),
            response: ToolResponse(ok: false, source: "fixture", message: "denied"),
            includeStructuredContent: true
        )
        XCTAssertNil(object["error"])
        let result = try resultObject(object)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertNotNil(result["structuredContent"])
    }

    func testResponseWriterKeepsConcurrentJSONLinesIntact() throws {
        let pipe = Pipe()
        let writer = SerializedMCPResponseWriter(handle: pipe.fileHandleForWriting)
        let group = DispatchGroup()

        for id in 0..<64 {
            group.enter()
            DispatchQueue.global().async {
                writer.write(["jsonrpc": "2.0", "id": id, "result": [:]])
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        try pipe.fileHandleForWriting.close()

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        let lines = output.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 64)
        let ids = try Set(lines.map { line -> Int in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            )
            return try XCTUnwrap(object["id"] as? Int)
        })
        XCTAssertEqual(ids, Set(0..<64))
    }

    func testResponseWriterFailsClosedOnNonDrainingStdoutWithinDeadline() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let writer = SerializedMCPResponseWriter(
            handle: pipe.fileHandleForWriting,
            writeTimeout: 0.05,
            maximumMessageBytes: 4 * 1_024 * 1_024
        )
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["payload": String(repeating: "x", count: 3 * 1_024 * 1_024)]
        ]

        let started = Date()
        XCTAssertEqual(writer.write(object), .failed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(writer.isOperational)

        // Once a partial JSON line or timeout has made framing unusable, later writes fail
        // immediately instead of accumulating behind the first response.
        let retryStarted = Date()
        XCTAssertEqual(writer.write(["jsonrpc": "2.0", "id": 2, "result": [:]]), .failed)
        XCTAssertLessThan(Date().timeIntervalSince(retryStarted), 0.1)
    }

    func testResponseWriterSuppressesCancelledReservationBeforeWriting() {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let writer = SerializedMCPResponseWriter(handle: pipe.fileHandleForWriting)
        XCTAssertEqual(
            writer.write(["jsonrpc": "2.0", "id": 1, "result": [:]], shouldStart: { false }),
            .suppressed
        )
        XCTAssertTrue(writer.isOperational)
    }

    func testWriterFailureBetweenInitialCheckAndReservationPreventsDispatchAdmission() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let writer = SerializedMCPResponseWriter(
            handle: pipe.fileHandleForWriting,
            maximumMessageBytes: 64
        )
        let registry = M3MCPInFlightRequestRegistry()

        // Model startToolCall's first optimistic check, then fail the writer only after the ID has
        // been reserved—the exact interleaving that previously escaped cancelAll().
        XCTAssertTrue(writer.isOperational)
        let reservation = try XCTUnwrap(registry.reserve(.integer(91)))
        XCTAssertEqual(
            writer.write([
                "jsonrpc": "2.0",
                "id": 1,
                // Invalid JSON is an internal protocol invariant failure and still poisons the
                // writer even though a merely oversized complete object no longer does.
                "result": ["payload": Double.nan]
            ]),
            .failed
        )

        XCTAssertFalse(
            MCPServer.retainReservationIfWriterOperational(
                reservation,
                registry: registry,
                writer: writer
            )
        )
        XCTAssertEqual(registry.count, 0)
    }

    func testNearHTTPBoundaryEscapeAmplificationBecomesBoundedToolErrorWithoutPoisoningWriter() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let writer = SerializedMCPResponseWriter(handle: pipe.fileHandleForWriting)
        // With the real ToolResponse envelope this is exactly one byte below the shared 8 MiB
        // local-HTTP body cap. Embedding that JSON as MCP text escapes every backslash again and
        // makes the outer JSON-RPC candidate seven bytes larger than the strict 16 MiB stdout cap.
        let providerResponse = ToolResponse(
            ok: true,
            source: "x",
            message: String(repeating: "\\", count: 4_194_255)
        )
        let localBody = try M3JSON.makeEncoder().encode(providerResponse)
        XCTAssertEqual(localBody.count, LocalHTTPResponseParser.maximumBodyBytes - 1)

        let candidate = MCPServer.makeToolResultObject(
            id: .integer(77),
            response: providerResponse,
            includeStructuredContent: false
        )
        let amplified = try JSONSerialization.data(withJSONObject: candidate)
        XCTAssertEqual(amplified.count, 16 * 1_024 * 1_024 + 7)

        XCTAssertEqual(
            MCPServer.writeToolResult(
                id: .integer(77),
                response: providerResponse,
                includeStructuredContent: false,
                writer: writer
            ),
            .written
        )
        XCTAssertTrue(writer.isOperational)
        XCTAssertEqual(
            writer.write(["jsonrpc": "2.0", "id": 78, "result": [:]]),
            .written
        )
        try pipe.fileHandleForWriting.close()

        let lines = pipe.fileHandleForReading.readDataToEndOfFile().split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2)
        let replacement = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any]
        )
        XCTAssertEqual(replacement["id"] as? Int, 77)
        let result = try XCTUnwrap(replacement["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(textContent(in: result)?.contains("output safety limit") == true)

        let next = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any]
        )
        XCTAssertEqual(next["id"] as? Int, 78)
    }

    func testSocketCancellationUsesShutdownToUnblockPeer() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }

        let controller = SocketCancellationController()
        XCTAssertTrue(controller.register(descriptors[0]))
        controller.cancel()

        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(descriptors[1], &byte, 1), 0)
        controller.unregister(descriptors[0])
    }

    func testLateCancellationDoesNotTouchAnUnregisteredDescriptor() throws {
        var original = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &original), 0)
        let controller = SocketCancellationController()
        XCTAssertTrue(controller.register(original[0]))
        controller.unregister(original[0])
        close(original[0])
        close(original[1])

        // Darwin normally reuses the just-released descriptor numbers here. The assertion is valid
        // even if another test thread wins that race: no descriptor is registered with controller.
        var replacement = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &replacement), 0)
        defer {
            close(replacement[0])
            close(replacement[1])
        }

        controller.cancel()
        var sent: UInt8 = 0x5A
        XCTAssertEqual(Darwin.write(replacement[0], &sent, 1), 1)
        var received: UInt8 = 0
        XCTAssertEqual(Darwin.read(replacement[1], &received, 1), 1)
        XCTAssertEqual(received, sent)
    }

    func testCancellingLocalAppClientInterruptsHeldUnixSocketRead() async throws {
        let fixture = try HeldUnixSocketFixture()
        defer { fixture.close() }
        let client = LocalAppClient(socketURL: fixture.socketURL, timeout: 30)

        let call = Task {
            await client.call(tool: "source_status", arguments: [:])
        }
        XCTAssertEqual(fixture.requestReceived.wait(timeout: .now() + 2), .success)

        call.cancel()
        XCTAssertEqual(fixture.peerClosed.wait(timeout: .now() + 2), .success)
        let response = await call.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.source, "M3MCPBridge")
        XCTAssertFalse(response.message?.isEmpty ?? true)
    }

    func testCancellationAfterSocketRegistrationCannotDispatchAfterConnect() async throws {
        let fixture = try HeldUnixSocketFixture()
        defer { fixture.close() }
        let client = LocalAppClient(
            socketURL: fixture.socketURL,
            timeout: 2,
            registeredSocketHook: { controller in
                // This is the exact old race: shutdown runs while the descriptor is registered but
                // not connected, so Darwin can return ENOTCONN. The post-connect locked recheck must
                // still stop the first request byte.
                controller.cancel()
            }
        )

        let response = await client.call(tool: "source_status", arguments: [:])
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("cancelled") == true)
        XCTAssertEqual(fixture.requestReceived.wait(timeout: .now() + 0.2), .timedOut)
    }

    func testDefaultLocalAppTimeoutOutlivesMaximumVoiceMemoProviderDeadline() {
        XCTAssertEqual(
            LocalAppClient.defaultResponseTimeout,
            TimeInterval(VoiceMemoTranscriptionTimeoutPolicy.transportResponseTimeoutSeconds)
        )
        XCTAssertGreaterThan(
            LocalAppClient.defaultResponseTimeout,
            TimeInterval(VoiceMemoTranscriptionTimeoutPolicy.maximumSeconds)
        )
    }

    func testLocalAppClientExplainsGenericPayloadTooLargeResponse() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "error": "Request body is too large."
        ])
        let response = LocalAppClient.decodeToolResponse(
            LocalHTTPResponse(status: 413, body: body)
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.source, "M3MCPBridge")
        XCTAssertTrue(response.message?.contains("HTTP 413") == true)
        XCTAssertTrue(response.message?.contains("Request body is too large") == true)
        XCTAssertFalse(response.message?.contains("unreadable") == true)
    }

    func testLocalAppClientStillDecodesProviderToolResponseAtHTTP400() throws {
        let expected = ToolResponse(ok: false, source: "Calendar", message: "Denied")
        let body = try M3JSON.makeEncoder().encode(expected)
        let response = LocalAppClient.decodeToolResponse(
            LocalHTTPResponse(status: 400, body: body)
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.source, "Calendar")
        XCTAssertEqual(response.message, "Denied")
    }

    func testLocalAppClientTimesOutWhenUnixSocketHoldsResponseOpen() async throws {
        let fixture = try HeldUnixSocketFixture()
        defer { fixture.close() }
        let client = LocalAppClient(socketURL: fixture.socketURL, timeout: 1)

        let started = Date()
        let response = await client.call(tool: "source_status", arguments: [:])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.source, "M3MCPBridge")
        XCTAssertTrue(response.message?.contains("Reading from the local socket failed") == true)
        XCTAssertGreaterThanOrEqual(elapsed, 0.8)
        XCTAssertLessThan(elapsed, 3)
        XCTAssertEqual(fixture.peerClosed.wait(timeout: .now() + 2), .success)
    }

    func testLocalAppClientAbsoluteDeadlineRejectsResponseTrickle() async throws {
        let fixture = try ScriptedUnixSocketFixture(
            response: Data(repeating: 0x41, count: 80),
            interByteDelayMicroseconds: 50_000
        )
        defer { fixture.close() }
        let client = LocalAppClient(socketURL: fixture.socketURL, timeout: 0.25)

        let started = Date()
        let response = await client.call(tool: "source_status", arguments: [:])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("absolute response deadline") == true)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertEqual(fixture.peerClosed.wait(timeout: .now() + 2), .success)
    }

    func testLocalAppClientRejectsOversizedDeclaredBodyBeforePeerEOF() async throws {
        let wire = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: \(LocalHTTPResponseParser.maximumBodyBytes + 1)\r\n\r\n".utf8
        )
        let fixture = try ScriptedUnixSocketFixture(response: wire)
        defer { fixture.close() }
        let client = LocalAppClient(socketURL: fixture.socketURL, timeout: 10)

        let started = Date()
        let response = await client.call(tool: "source_status", arguments: [:])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message?.contains("bodyTooLarge") == true)
        XCTAssertEqual(fixture.peerClosed.wait(timeout: .now() + 2), .success)
    }

    func testLocalAppClientReturnsAtDeclaredBodyWithoutWaitingForEOF() async throws {
        let body = try M3JSON.makeEncoder().encode(
            ToolResponse(ok: true, source: "fixture", message: "complete")
        )
        var wire = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        wire.append(body)
        let fixture = try ScriptedUnixSocketFixture(response: wire)
        defer { fixture.close() }
        let client = LocalAppClient(socketURL: fixture.socketURL, timeout: 10)

        let started = Date()
        let response = await client.call(tool: "source_status", arguments: [:])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.source, "fixture")
        XCTAssertEqual(response.message, "complete")
        XCTAssertEqual(fixture.peerClosed.wait(timeout: .now() + 2), .success)
    }

    private func resultObject(_ response: [String: Any]) throws -> [String: Any] {
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func textContent(in result: [String: Any]) -> String? {
        guard let content = result["content"] as? [[String: Any]],
              let first = content.first,
              first["type"] as? String == "text"
        else { return nil }
        return first["text"] as? String
    }
}

private final class HeldUnixSocketFixture {
    let socketURL: URL
    let requestReceived = DispatchSemaphore(value: 0)
    let peerClosed = DispatchSemaphore(value: 0)

    private let listener: Int32
    private let queue = DispatchQueue(label: "MCPServerFormattingTests.HeldUnixSocketFixture")

    init() throws {
        let suffix = UUID().uuidString.prefix(12)
        socketURL = URL(fileURLWithPath: "/private/tmp/m3mcp-cancel-\(suffix).sock")
        unlink(socketURL.path)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENFILE) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, socketURL.path, capacity)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                bind(listener, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(listener)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        guard listen(listener, 1) == 0 else {
            let code = errno
            Darwin.close(listener)
            unlink(socketURL.path)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        queue.async { [listener, requestReceived, peerClosed] in
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }

            var buffer = [UInt8](repeating: 0, count: 4_096)
            let firstRead = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(connection, raw.baseAddress, raw.count)
            }
            guard firstRead > 0 else {
                peerClosed.signal()
                return
            }
            requestReceived.signal()

            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(connection, raw.baseAddress, raw.count)
                }
                if count == 0 {
                    peerClosed.signal()
                    return
                }
                if count < 0, errno != EINTR {
                    peerClosed.signal()
                    return
                }
            }
        }
    }

    func close() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketURL.path)
    }
}

private final class ScriptedUnixSocketFixture {
    let socketURL: URL
    let requestReceived = DispatchSemaphore(value: 0)
    let peerClosed = DispatchSemaphore(value: 0)

    private let listener: Int32
    private let queue = DispatchQueue(label: "MCPServerFormattingTests.ScriptedUnixSocketFixture")

    init(response: Data, interByteDelayMicroseconds: useconds_t? = nil) throws {
        let suffix = UUID().uuidString.prefix(12)
        socketURL = URL(fileURLWithPath: "/private/tmp/m3mcp-scripted-\(suffix).sock")
        unlink(socketURL.path)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENFILE) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, socketURL.path, capacity)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                bind(listener, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(listener)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        guard listen(listener, 1) == 0 else {
            let code = errno
            Darwin.close(listener)
            unlink(socketURL.path)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        queue.async { [listener, requestReceived, peerClosed, response, interByteDelayMicroseconds] in
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }

            var noSigPipe: Int32 = 1
            _ = setsockopt(
                connection,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )

            var requestBuffer = [UInt8](repeating: 0, count: 4_096)
            let firstRead = requestBuffer.withUnsafeMutableBytes { raw in
                Darwin.read(connection, raw.baseAddress, raw.count)
            }
            guard firstRead > 0 else {
                peerClosed.signal()
                return
            }
            requestReceived.signal()

            let sentAll: Bool
            if let interByteDelayMicroseconds {
                sentAll = response.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return true }
                    for offset in 0..<raw.count {
                        while true {
                            let written = Darwin.send(
                                connection,
                                base.advanced(by: offset),
                                1,
                                0
                            )
                            if written == 1 { break }
                            if written < 0, errno == EINTR { continue }
                            return false
                        }
                        usleep(interByteDelayMicroseconds)
                    }
                    return true
                }
            } else {
                sentAll = response.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return true }
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.send(
                            connection,
                            base.advanced(by: offset),
                            raw.count - offset,
                            0
                        )
                        if written > 0 {
                            offset += written
                            continue
                        }
                        if written < 0, errno == EINTR { continue }
                        return false
                    }
                    return true
                }
            }

            guard sentAll else {
                peerClosed.signal()
                return
            }

            // Deliberately retain the connection after the scripted bytes. A streaming client must
            // return at Content-Length (or reject the header) rather than waiting for this EOF.
            while true {
                let count = requestBuffer.withUnsafeMutableBytes { raw in
                    Darwin.read(connection, raw.baseAddress, raw.count)
                }
                if count == 0 {
                    peerClosed.signal()
                    return
                }
                if count < 0, errno != EINTR {
                    peerClosed.signal()
                    return
                }
            }
        }
    }

    func close() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketURL.path)
    }
}
