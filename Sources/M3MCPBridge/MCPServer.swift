import Foundation
import M3MCPCore

final class MCPServer {
    private let client = LocalAppClient()

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            guard request["id"] != nil else {
                continue
            }

            let response = await handle(request)
            write(response)
        }
    }

    private func handle(_ request: [String: Any]) async -> [String: Any] {
        let id = request["id"] ?? NSNull()
        guard let method = request["method"] as? String else {
            return error(id: id, code: -32600, message: "Invalid request")
        }

        switch method {
        case "initialize":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [
                        "tools": [:]
                    ],
                    "serverInfo": [
                        "name": "m3mcp",
                        "version": m3mcpVersion
                    ]
                ]
            ]
        case "ping":
            return ["jsonrpc": "2.0", "id": id, "result": [:]]
        case "tools/list":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "tools": ToolCatalog.tools.map { tool in
                        [
                            "name": tool.name,
                            "description": tool.description,
                            "inputSchema": tool.schema
                        ]
                    }
                ]
            ]
        case "tools/call":
            return await callTool(id: id, request: request)
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func callTool(id: Any, request: [String: Any]) async -> [String: Any] {
        guard let params = request["params"] as? [String: Any],
              let name = params["name"] as? String
        else {
            return error(id: id, code: -32602, message: "Missing tool name")
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let result = await client.call(tool: name, arguments: arguments)
        let text = render(result)

        return [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ],
                "isError": !result.ok
            ]
        ]
    }

    private func render(_ response: ToolResponse) -> String {
        if let data = try? M3JSON.makePrettyEncoder().encode(response),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return response.message ?? "No response"
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }

    private func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return
        }

        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
