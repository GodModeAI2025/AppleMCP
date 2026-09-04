import Darwin
import Foundation
import M3MCPCore

final class MCPServer {
    /// Structured content repeats the same JSON that legacy clients need in the text block. Keep
    /// that compatibility copy for normal results, but never double a large binary-like payload.
    static let maximumStructuredContentBytes = 1_000_000

    private let client = LocalAppClient()
    private let inFlightRequests = M3MCPInFlightRequestRegistry()
    private let responseWriter = SerializedMCPResponseWriter(handle: .standardOutput)
    private var protocolEngine = M3MCPProtocolEngine(
        allowedToolNames: Set(ToolCatalog.tools.map(\.name))
    )

    func run() async {
        var reader = BoundedStdioMessageReader(
            handle: .standardInput,
            maximumMessageBytes: M3MCPProtocolEngine.defaultMaximumMessageBytes
        )

        while true {
            switch reader.next() {
            case .message(let data):
                let disposition = protocolEngine.process(data)
                handle(disposition)

            case .oversized:
                writeResponse(responseObject(
                    M3MCPProtocolResponse(
                        id: nil,
                        payload: .error(
                            code: -32700,
                            message: "Parse error: message exceeds the size limit"
                        )
                    )
                ))

            case .endOfFile:
                inFlightRequests.cancelAll()
                return
            }
        }
    }

    private func handle(_ disposition: M3MCPProtocolDisposition) {
        switch disposition {
        case .noResponse:
            return

        case .cancelRequest(let id):
            _ = inFlightRequests.cancel(id)

        case .response(let response):
            if let id = response.id, inFlightRequests.isInFlight(id) {
                writeDuplicateIDError(id)
            } else {
                writeResponse(responseObject(response))
            }

        case .listTools(let id, let includeAnnotations):
            guard !inFlightRequests.isInFlight(id) else {
                writeDuplicateIDError(id)
                return
            }
            let tools = ToolCatalog.tools.map { tool in
                Self.makeToolObject(tool, includeAnnotations: includeAnnotations)
            }
            writeResponse(Self.successObject(id: id, result: ["tools": tools]))

        case .callTool(let id, let name, let arguments, let includeStructuredContent):
            startToolCall(
                id: id,
                name: name,
                arguments: arguments,
                includeStructuredContent: includeStructuredContent
            )
        }
    }

    private func startToolCall(
        id: M3MCPRequestID,
        name: String,
        arguments: [String: JSONValue],
        includeStructuredContent: Bool
    ) {
        guard responseWriter.isOperational else {
            // stdout has already failed or exceeded its backpressure deadline. Starting more local
            // work could only consume resources because no protocol response can be delivered.
            return
        }
        guard let reservation = inFlightRequests.reserve(id) else {
            if inFlightRequests.isInFlight(id) {
                writeDuplicateIDError(id)
            } else {
                writeResponse(responseObject(
                    M3MCPProtocolResponse(
                        id: id,
                        payload: .error(code: -32000, message: "Too many in-flight tool calls")
                    )
                ))
            }
            return
        }

        // A different response can permanently fail stdout between the optimistic check above and
        // this reservation. Recheck after the reservation is visible so that writer failure either
        // rejects it here or cancelAll() observes and cancels the newly visible reservation.
        guard Self.retainReservationIfWriterOperational(
            reservation,
            registry: inFlightRequests,
            writer: responseWriter
        ) else {
            return
        }

        let client = self.client
        let registry = inFlightRequests
        let writer = responseWriter

        let task = Task {
            guard writer.isOperational, registry.responseIsWanted(reservation) else {
                _ = registry.finish(reservation)
                return
            }
            let foundationArguments = arguments.mapValues(\.foundationValue)
            let result = await client.call(tool: name, arguments: foundationArguments)
            guard registry.responseIsWanted(reservation) else {
                // MCP cancellation notifications do not receive a response. Suppress the eventual
                // tool result as well, even if the app completed while transport shutdown raced.
                _ = registry.finish(reservation)
                return
            }
            let outcome = Self.writeToolResult(
                id: id,
                response: result,
                includeStructuredContent: includeStructuredContent,
                writer: writer,
                shouldStart: { registry.responseIsWanted(reservation) }
            )
            _ = registry.finish(reservation)
            if outcome == .failed {
                // Keep other reservations occupied until their cancellation unwinds. No additional
                // calls are admitted once the writer is failed.
                registry.cancelAll()
            }
        }

        _ = registry.attachCancellationHandler(to: reservation) {
            task.cancel()
        }
    }

    /// Second-phase admission check for the two independently locked components. The reservation
    /// is already visible before the writer is rechecked; if stdout failed in the gap, remove it
    /// without dispatching a provider call. If failure happens after this check, the writer's
    /// cancelAll path sees the live reservation and requests cancellation.
    static func retainReservationIfWriterOperational(
        _ reservation: M3MCPInFlightRequestRegistry.Reservation,
        registry: M3MCPInFlightRequestRegistry,
        writer: SerializedMCPResponseWriter
    ) -> Bool {
        guard writer.isOperational, registry.responseIsWanted(reservation) else {
            _ = registry.finish(reservation)
            return false
        }
        return true
    }

    private func writeDuplicateIDError(_ id: M3MCPRequestID) {
        writeResponse(responseObject(
            M3MCPProtocolResponse(
                id: id,
                payload: .error(code: -32600, message: "Duplicate in-flight request id")
            )
        ))
    }

    private func writeResponse(_ object: [String: Any]) {
        let outcome = responseWriter.write(object)
        if outcome == .oversized {
            // Non-tool protocol responses are expected to be tiny, but keep an internal bug from
            // silently dropping a request or poisoning an otherwise intact stdout stream.
            let fallback: [String: Any] = [
                "jsonrpc": "2.0",
                "id": object["id"] ?? NSNull(),
                "error": [
                    "code": -32603,
                    "message": "Response exceeds the MCP output safety limit"
                ]
            ]
            if responseWriter.write(fallback) == .failed {
                inFlightRequests.cancelAll()
            }
        } else if outcome == .failed {
            inFlightRequests.cancelAll()
        }
    }

    static func makeToolObject(_ tool: MCPTool, includeAnnotations: Bool) -> [String: Any] {
        var object: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": tool.schema
        ]

        if includeAnnotations {
            // These MCP fields are advisory hints for client UX. The immutable launch policy and
            // app-side dispatch checks remain the actual authorization boundaries.
            object["annotations"] = [
                "readOnlyHint": tool.securityHints.readOnly,
                "destructiveHint": tool.securityHints.destructive,
                "idempotentHint": tool.securityHints.idempotent,
                "openWorldHint": tool.securityHints.openWorld
            ]
        }
        return object
    }

    static func makeToolResultObject(
        id: M3MCPRequestID,
        response: ToolResponse,
        includeStructuredContent: Bool
    ) -> [String: Any] {
        let encoded = try? M3JSON.makeEncoder().encode(response)
        let text: String
        if let encoded, encoded.count > maximumStructuredContentBytes,
           let rendered = String(data: encoded, encoding: .utf8) {
            // Pretty-printing a multi-megabyte result creates another large allocation for no
            // semantic benefit. Compact JSON remains compatible with legacy text-only clients.
            text = rendered
        } else if let pretty = try? M3JSON.makePrettyEncoder().encode(response),
           let rendered = String(data: pretty, encoding: .utf8) {
            text = rendered
        } else {
            text = response.message ?? "No response"
        }

        var result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ],
            "isError": !response.ok
        ]

        // Structured tool output is a 2025-06-18 feature. Retaining the text block is required for
        // backwards compatibility with clients that only consume unstructured content.
        if includeStructuredContent,
           let encoded,
           encoded.count <= maximumStructuredContentBytes,
           let structured = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            result["structuredContent"] = structured
        }

        return successObject(id: id, result: result)
    }

    /// Writes one tool response without letting a complete-but-oversized candidate poison stdout.
    /// No bytes have been written when the writer reports `.oversized`, so a small normal MCP tool
    /// error for the same request ID can safely replace it. Actual serialization/descriptor/partial
    /// write failures remain fail-closed in `SerializedMCPResponseWriter`.
    @discardableResult
    static func writeToolResult(
        id: M3MCPRequestID,
        response: ToolResponse,
        includeStructuredContent: Bool,
        writer: SerializedMCPResponseWriter,
        shouldStart: () -> Bool = { true }
    ) -> SerializedMCPResponseWriter.Outcome {
        let candidate = makeToolResultObject(
            id: id,
            response: response,
            includeStructuredContent: includeStructuredContent
        )
        let outcome = writer.write(candidate, shouldStart: shouldStart)
        guard outcome == .oversized else { return outcome }

        let boundedFailure = makeToolResultObject(
            id: id,
            response: ToolResponse(
                ok: false,
                source: "M3MCPBridge",
                message: "The tool result exceeds the MCP output safety limit. Narrow the request."
            ),
            includeStructuredContent: includeStructuredContent
        )
        return writer.write(boundedFailure, shouldStart: shouldStart)
    }

    private func responseObject(_ response: M3MCPProtocolResponse) -> [String: Any] {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": response.id?.foundationValue ?? NSNull()
        ]
        switch response.payload {
        case .result(let result):
            object["result"] = result.foundationValue
        case .error(let code, let message):
            object["error"] = [
                "code": code,
                "message": message
            ]
        }
        return object
    }

    private static func successObject(id: M3MCPRequestID, result: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id.foundationValue,
            "result": result
        ]
    }

}

final class SerializedMCPResponseWriter: @unchecked Sendable {
    enum Outcome: Equatable {
        case written
        case suppressed
        /// The complete JSON object exceeded the configured line budget. No byte was written and
        /// the writer remains usable, so the caller may substitute a bounded response.
        case oversized
        case failed
    }

    private let descriptor: Int32
    private let writeTimeout: TimeInterval
    private let maximumMessageBytes: Int
    private let lock = NSLock()
    private var failed = false

    init(
        handle: FileHandle,
        writeTimeout: TimeInterval = 15,
        maximumMessageBytes: Int = 16 * 1_024 * 1_024
    ) {
        descriptor = handle.fileDescriptor
        let finiteTimeout = writeTimeout.isFinite ? writeTimeout : 15
        self.writeTimeout = min(max(finiteTimeout, 0.001), 60)
        self.maximumMessageBytes = max(1, maximumMessageBytes)

        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 {
            failed = true
        }
    }

    var isOperational: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !failed
    }

    @discardableResult
    func write(
        _ object: [String: Any],
        shouldStart: () -> Bool = { true }
    ) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return .failed }
        guard shouldStart() else { return .suppressed }
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            failed = true
            return .failed
        }
        guard data.count < maximumMessageBytes else { return .oversized }
        // Serialization of a near-limit response can be measurable. Re-linearize cancellation at
        // the last safe point before the first byte; after a partial JSON line starts, suppression
        // is no longer possible without corrupting framing.
        guard shouldStart() else { return .suppressed }
        data.append(0x0A)

        guard writeAll(data) else {
            // A partial line cannot be recovered without corrupting JSON-RPC framing. Permanently
            // fail this writer so callers cannot accumulate more queued output behind it.
            failed = true
            return .failed
        }
        return .written
    }

    private func writeAll(_ data: Data) -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(writeTimeout * 1_000_000_000)
        let (candidateDeadline, overflowed) = start.addingReportingOverflow(duration)
        let deadline = overflowed ? UInt64.max : candidateDeadline

        return data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return true }
            var remaining = raw.count

            while remaining > 0 {
                let written = Darwin.write(descriptor, base, remaining)
                if written > 0 {
                    base = base.advanced(by: written)
                    remaining -= written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    return false
                }

                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                let nanoseconds = deadline - now
                let milliseconds = max(1, (nanoseconds + 999_999) / 1_000_000)
                var readiness = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT | POLLHUP | POLLERR),
                    revents: 0
                )
                let ready = Darwin.poll(
                    &readiness,
                    1,
                    Int32(min(milliseconds, UInt64(Int32.max)))
                )
                if ready < 0, errno == EINTR { continue }
                guard ready > 0,
                      readiness.revents & Int16(POLLNVAL | POLLHUP | POLLERR) == 0 else {
                    return false
                }
            }
            return true
        }
    }
}

private extension M3MCPRequestID {
    var foundationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return value
        }
    }
}

private extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.foundationValue)
        case .array(let value):
            return value.map(\.foundationValue)
        case .null:
            return NSNull()
        }
    }
}

private struct BoundedStdioMessageReader {
    enum Event {
        case message(Data)
        case oversized
        case endOfFile
    }

    private let handle: FileHandle
    private let maximumMessageBytes: Int
    private let readChunkBytes = 64 * 1024
    private var buffer = Data()
    private var discardingOversizedMessage = false
    private var reachedEndOfFile = false

    init(handle: FileHandle, maximumMessageBytes: Int) {
        self.handle = handle
        self.maximumMessageBytes = max(1, maximumMessageBytes)
    }

    mutating func next() -> Event {
        while true {
            if discardingOversizedMessage {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    buffer.removeSubrange(buffer.startIndex...newline)
                    discardingOversizedMessage = false
                    continue
                }
                buffer.removeAll(keepingCapacity: true)
            } else if let newline = buffer.firstIndex(of: 0x0A) {
                var message = Data(buffer[..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if message.last == 0x0D {
                    message.removeLast()
                }
                return message.count <= maximumMessageBytes ? .message(message) : .oversized
            } else if buffer.count > maximumMessageBytes {
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedMessage = true
                return .oversized
            }

            if reachedEndOfFile {
                if discardingOversizedMessage {
                    discardingOversizedMessage = false
                    return .endOfFile
                }
                guard !buffer.isEmpty else { return .endOfFile }
                let message = buffer
                buffer.removeAll(keepingCapacity: true)
                return message.count <= maximumMessageBytes ? .message(message) : .oversized
            }

            let chunk = readChunk()
            if chunk.isEmpty {
                reachedEndOfFile = true
            } else {
                buffer.append(chunk)
            }
        }
    }

    private func readChunk() -> Data {
        var bytes = [UInt8](repeating: 0, count: readChunkBytes)
        while true {
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(handle.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                return Data(bytes.prefix(count))
            }
            if count == 0 {
                return Data()
            }
            if errno != EINTR {
                return Data()
            }
        }
    }
}
