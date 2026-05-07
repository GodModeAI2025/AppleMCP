import Foundation

public let m3mcpDefaultPort: UInt16 = 47651
public let m3mcpVersion = "0.1.0"

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        default:
            return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            return Bool(value)
        default:
            return nil
        }
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String, default fallback: String = "") -> String {
        self[key]?.stringValue ?? fallback
    }

    func int(_ key: String, default fallback: Int) -> Int {
        self[key]?.intValue ?? fallback
    }

    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        self[key]?.boolValue ?? fallback
    }
}

public struct DataItem: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let kind: String
    public let source: String
    public let preview: String?
    public let metadata: [String: String]

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        kind: String,
        source: String,
        preview: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.source = source
        self.preview = preview
        self.metadata = metadata
    }
}

public struct ToolResponse: Codable, Sendable {
    public let ok: Bool
    public let source: String
    public let items: [DataItem]
    public let message: String?

    public init(ok: Bool, source: String, items: [DataItem] = [], message: String? = nil) {
        self.ok = ok
        self.source = source
        self.items = items
        self.message = message
    }
}

public struct ServiceHealth: Codable, Identifiable, Sendable {
    public var id: String { name }

    public let name: String
    public let endpoint: String
    public let mode: String
    public let state: String

    public init(name: String, endpoint: String, mode: String, state: String) {
        self.name = name
        self.endpoint = endpoint
        self.mode = mode
        self.state = state
    }
}

public struct ActivityEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let at: Date
    public let endpoint: String
    public let provider: String
    public let status: String
    public let detail: String
    public let durationMilliseconds: Int
    public let toolName: String
    public let inputJSON: String?
    public let outputJSON: String?

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        endpoint: String,
        provider: String,
        status: String,
        detail: String,
        durationMilliseconds: Int,
        toolName: String = "",
        inputJSON: String? = nil,
        outputJSON: String? = nil
    ) {
        self.id = id
        self.at = at
        self.endpoint = endpoint
        self.provider = provider
        self.status = status
        self.detail = detail
        self.durationMilliseconds = durationMilliseconds
        self.toolName = toolName
        self.inputJSON = inputJSON
        self.outputJSON = outputJSON
    }
}

public struct StatusResponse: Codable, Sendable {
    public let ok: Bool
    public let version: String
    public let port: UInt16
    public let services: [ServiceHealth]
    public let recentActivity: [ActivityEntry]

    public init(ok: Bool, version: String, port: UInt16, services: [ServiceHealth], recentActivity: [ActivityEntry]) {
        self.ok = ok
        self.version = version
        self.port = port
        self.services = services
        self.recentActivity = recentActivity
    }
}
