import CoreFoundation
import Foundation

/// MCP protocol revisions that this bridge has explicit compatibility coverage for.
///
/// Revisions are deliberately enumerated instead of compared as arbitrary date strings. A future
/// revision can change lifecycle or message semantics and must not be advertised by accident.
public enum M3MCPProtocolRevision: String, CaseIterable, Equatable, Sendable {
    case v2024_11_05 = "2024-11-05"
    case v2025_03_26 = "2025-03-26"
    case v2025_06_18 = "2025-06-18"
    case v2025_11_25 = "2025-11-25"

    public static let newestSupported: M3MCPProtocolRevision = .v2025_11_25

    /// Tool behavior annotations were added in the 2025-03-26 revision.
    public var supportsToolAnnotations: Bool {
        self != .v2024_11_05
    }

    /// Structured tool results were added in the 2025-06-18 revision.
    public var supportsStructuredToolResults: Bool {
        switch self {
        case .v2024_11_05, .v2025_03_26:
            return false
        case .v2025_06_18, .v2025_11_25:
            return true
        }
    }
}

/// JSON-RPC request identifiers accepted by MCP. Numeric identifiers are constrained to the exact
/// integer range shared by common JSON implementations so a reply cannot silently change the ID.
public enum M3MCPRequestID: Equatable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
}

public struct M3MCPProtocolResponse: Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case result(JSONValue)
        case error(code: Int, message: String)
    }

    /// `nil` is serialized as JSON null for parse and invalid-request errors.
    public let id: M3MCPRequestID?
    public let payload: Payload

    public init(id: M3MCPRequestID?, payload: Payload) {
        self.id = id
        self.payload = payload
    }
}

/// A pure protocol decision. The bridge performs I/O only for `callTool`; all validation and
/// lifecycle state transitions happen before that action can be returned.
public enum M3MCPProtocolDisposition: Equatable, Sendable {
    case noResponse
    case response(M3MCPProtocolResponse)
    case listTools(id: M3MCPRequestID, includeAnnotations: Bool)
    case cancelRequest(id: M3MCPRequestID)
    case callTool(
        id: M3MCPRequestID,
        name: String,
        arguments: [String: JSONValue],
        includeStructuredContent: Bool
    )
}

/// Stateful MCP/JSON-RPC validator for one stdio connection.
public struct M3MCPProtocolEngine: Sendable {
    public enum Phase: Equatable, Sendable {
        case uninitialized
        case awaitingInitialized(M3MCPProtocolRevision)
        case ready(M3MCPProtocolRevision)
    }

    public static let defaultMaximumMessageBytes = 1_048_576

    private static let maximumMethodBytes = 128
    private static let maximumIdentifierBytes = 256
    private static let maximumProtocolVersionBytes = 32
    private static let maximumJSONDepth = 32
    private static let maximumJSONNodes = 50_000
    private static let maximumExactJSONInteger: Double = 9_007_199_254_740_991

    private let allowedToolNames: Set<String>
    private let maximumMessageBytes: Int
    public private(set) var phase: Phase = .uninitialized

    public init(
        allowedToolNames: Set<String>,
        maximumMessageBytes: Int = M3MCPProtocolEngine.defaultMaximumMessageBytes
    ) {
        self.allowedToolNames = allowedToolNames
        self.maximumMessageBytes = max(1, maximumMessageBytes)
    }

    public mutating func process(_ data: Data) -> M3MCPProtocolDisposition {
        guard data.count <= maximumMessageBytes else {
            return error(id: nil, code: -32700, message: "Parse error: message exceeds the size limit")
        }

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch _ {
            return error(id: nil, code: -32700, message: "Parse error")
        }

        var remainingNodes = Self.maximumJSONNodes
        guard Self.hasBoundedShape(raw, depth: 0, remainingNodes: &remainingNodes) else {
            return error(id: nil, code: -32600, message: "Invalid request: JSON structure is too complex")
        }

        guard let object = raw as? [String: Any] else {
            // MCP transports carry one JSON-RPC object per message. Batches and fragments are not
            // accepted, including for the legacy revision.
            return error(id: nil, code: -32600, message: "Invalid request")
        }

        guard object["jsonrpc"] as? String == "2.0" else {
            return error(id: nil, code: -32600, message: "Invalid request")
        }

        // We never issue requests to the client. Ignoring an unexpected response avoids creating a
        // response-to-response loop while still validating every inbound request/notification.
        guard let method = object["method"] as? String else {
            if object["result"] != nil || object["error"] != nil {
                return .noResponse
            }
            return error(id: nil, code: -32600, message: "Invalid request")
        }
        guard !method.isEmpty, method.utf8.count <= Self.maximumMethodBytes else {
            return error(id: nil, code: -32600, message: "Invalid request")
        }

        let hasID = object.keys.contains("id")
        let requestID: M3MCPRequestID?
        if hasID {
            guard let parsedID = Self.parseRequestID(object["id"] as Any) else {
                return error(id: nil, code: -32600, message: "Invalid request id")
            }
            requestID = parsedID
        } else {
            requestID = nil
        }

        let params: [String: Any]?
        if let rawParams = object["params"] {
            guard let objectParams = rawParams as? [String: Any] else {
                return requestID == nil
                    ? .noResponse
                    : error(id: requestID, code: -32602, message: "Invalid params")
            }
            params = objectParams
        } else {
            params = nil
        }

        // Valid notifications never receive JSON-RPC responses, even when their method is unknown
        // or their lifecycle transition is not applicable.
        guard let requestID else {
            return handleNotification(method: method, params: params)
        }

        return handleRequest(id: requestID, method: method, params: params)
    }

    private mutating func handleNotification(
        method: String,
        params: [String: Any]?
    ) -> M3MCPProtocolDisposition {
        switch method {
        case "notifications/initialized":
            if case .awaitingInitialized(let revision) = phase {
                phase = .ready(revision)
            }
        case "notifications/cancelled":
            guard let params,
                  let requestIDValue = params["requestId"],
                  let requestID = Self.parseRequestID(requestIDValue),
                  Self.isOptionalBoundedString(params["reason"])
            else {
                return .noResponse
            }
            return .cancelRequest(id: requestID)
        default:
            break
        }
        return .noResponse
    }

    private mutating func handleRequest(
        id: M3MCPRequestID,
        method: String,
        params: [String: Any]?
    ) -> M3MCPProtocolDisposition {
        switch method {
        case "initialize":
            return initialize(id: id, params: params)

        case "notifications/initialized", "notifications/cancelled":
            return error(id: id, code: -32600, message: "Notification method used as a request")

        case "ping":
            return .response(
                M3MCPProtocolResponse(id: id, payload: .result(.object([:])))
            )

        case "tools/list":
            guard case .ready(let revision) = phase else {
                return error(id: id, code: -32002, message: "Server initialization is not complete")
            }
            if params?["cursor"] != nil {
                return error(id: id, code: -32602, message: "Pagination cursor is not supported")
            }
            return .listTools(id: id, includeAnnotations: revision.supportsToolAnnotations)

        case "tools/call":
            guard case .ready(let revision) = phase else {
                return error(id: id, code: -32002, message: "Server initialization is not complete")
            }
            return callTool(id: id, params: params, revision: revision)

        default:
            return error(id: id, code: -32601, message: "Method not found")
        }
    }

    private mutating func initialize(
        id: M3MCPRequestID,
        params: [String: Any]?
    ) -> M3MCPProtocolDisposition {
        guard phase == .uninitialized else {
            return error(id: id, code: -32600, message: "Server is already initialized")
        }
        guard let params,
              let requestedVersion = params["protocolVersion"] as? String,
              !requestedVersion.isEmpty,
              requestedVersion.utf8.count <= Self.maximumProtocolVersionBytes,
              params["capabilities"] is [String: Any],
              let clientInfo = params["clientInfo"] as? [String: Any],
              Self.isBoundedNonemptyString(clientInfo["name"]),
              Self.isBoundedNonemptyString(clientInfo["version"])
        else {
            return error(id: id, code: -32602, message: "Invalid initialize params")
        }

        // MCP requires an exact echo when the requested revision is supported. Otherwise the
        // server offers its newest verified revision and the client decides whether to disconnect.
        let revision = M3MCPProtocolRevision(rawValue: requestedVersion) ?? .newestSupported
        phase = .awaitingInitialized(revision)

        let result: JSONValue = .object([
            "protocolVersion": .string(revision.rawValue),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "serverInfo": .object([
                "name": .string("m3mcp"),
                "version": .string(m3mcpVersion)
            ])
        ])
        return .response(M3MCPProtocolResponse(id: id, payload: .result(result)))
    }

    private func callTool(
        id: M3MCPRequestID,
        params: [String: Any]?,
        revision: M3MCPProtocolRevision
    ) -> M3MCPProtocolDisposition {
        guard let params,
              let name = params["name"] as? String,
              !name.isEmpty,
              name.utf8.count <= Self.maximumIdentifierBytes
        else {
            return error(id: id, code: -32602, message: "Invalid tool name")
        }

        // Discovery filtering is not the authorization boundary. Validate against both the closed
        // Core vocabulary and the immutable launch-policy set immediately before returning an
        // action that can reach the app.
        guard let toolName = M3MCPToolName(rawValue: name), allowedToolNames.contains(name) else {
            return error(id: id, code: -32602, message: "Unknown or disabled tool")
        }

        let arguments: [String: JSONValue]
        if let rawArguments = params["arguments"] {
            guard let rawObject = rawArguments as? [String: Any],
                  let converted = Self.jsonObject(rawObject)
            else {
                return error(id: id, code: -32602, message: "Tool arguments must be an object")
            }
            arguments = converted
        } else {
            arguments = [:]
        }

        if let validationError = M3MCPToolArgumentPolicy
            .forTool(toolName)
            .validationError(for: arguments, tool: toolName) {
            return error(
                id: id,
                code: -32602,
                message: validationError.clientMessage
            )
        }

        return .callTool(
            id: id,
            name: name,
            arguments: arguments,
            includeStructuredContent: revision.supportsStructuredToolResults
        )
    }

    private func error(
        id: M3MCPRequestID?,
        code: Int,
        message: String
    ) -> M3MCPProtocolDisposition {
        .response(M3MCPProtocolResponse(id: id, payload: .error(code: code, message: message)))
    }

    private static func parseRequestID(_ value: Any) -> M3MCPRequestID? {
        if let string = value as? String {
            guard string.utf8.count <= maximumIdentifierBytes else { return nil }
            return .string(string)
        }

        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }

        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              abs(double) <= maximumExactJSONInteger
        else {
            return nil
        }
        return .integer(Int64(double))
    }

    private static func isBoundedNonemptyString(_ value: Any?) -> Bool {
        guard let string = value as? String else { return false }
        return !string.isEmpty && string.utf8.count <= maximumIdentifierBytes
    }

    private static func isOptionalBoundedString(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let string = value as? String else { return false }
        return string.utf8.count <= maximumIdentifierBytes
    }

    private static func hasBoundedShape(
        _ value: Any,
        depth: Int,
        remainingNodes: inout Int
    ) -> Bool {
        guard depth <= maximumJSONDepth, remainingNodes > 0 else { return false }
        remainingNodes -= 1

        if let object = value as? [String: Any] {
            for (key, child) in object {
                guard key.utf8.count <= defaultMaximumMessageBytes,
                      hasBoundedShape(child, depth: depth + 1, remainingNodes: &remainingNodes)
                else { return false }
            }
        } else if let array = value as? [Any] {
            for child in array {
                guard hasBoundedShape(child, depth: depth + 1, remainingNodes: &remainingNodes) else {
                    return false
                }
            }
        }
        return true
    }

    private static func jsonObject(_ object: [String: Any]) -> [String: JSONValue]? {
        var converted: [String: JSONValue] = [:]
        converted.reserveCapacity(object.count)
        for (key, value) in object {
            guard let jsonValue = jsonValue(value) else { return nil }
            converted[key] = jsonValue
        }
        return converted
    }

    private static func jsonValue(_ value: Any) -> JSONValue? {
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            return double.isFinite ? .number(double) : nil
        case let object as [String: Any]:
            return jsonObject(object).map(JSONValue.object)
        case let array as [Any]:
            var converted: [JSONValue] = []
            converted.reserveCapacity(array.count)
            for child in array {
                guard let jsonChild = jsonValue(child) else { return nil }
                converted.append(jsonChild)
            }
            return .array(converted)
        default:
            return nil
        }
    }
}
