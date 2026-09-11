import Foundation

/// Renders configuration only on explicit user action. Callers use a placeholder for previews.
public enum ClientConfiguration {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case codex, json
        public var id: String { rawValue }
    }

    public static func environment(token: String, policy: M3MCPSecurityPolicy) -> [String: String] {
        var values = [CapabilityToken.environmentKey: token]
        for tool in policy.toolAvailability where tool.isEnabled {
            if let variable = tool.requiredEnvironmentVariable { values[variable] = "1" }
        }
        return values
    }

    public static func render(format: Format, bridgePath: String, token: String,
                              policy: M3MCPSecurityPolicy) throws -> String {
        let env = environment(token: token, policy: policy)
        switch format {
        case .json:
            let object: [String: Any] = ["mcpServers": ["m3mcp": ["command": bridgePath, "env": env]]]
            let data = try JSONSerialization.data(withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        case .codex:
            let entries = try env.keys.sorted().map { key in "\(key) = \(try quote(env[key]!))" }
            return "[mcp_servers.m3mcp]\ncommand = \(try quote(bridgePath))\n\n"
                + "[mcp_servers.m3mcp.env]\n" + entries.joined(separator: "\n") + "\n"
        }
    }

    // JSON basic-string escapes are valid TOML basic-string escapes; slash escaping is disabled.
    private static func quote(_ text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: text,
            options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
