import Foundation
import M3MCPCore

final class LocalAppClient {
    private let baseURLs = [
        URL(string: "http://127.0.0.1:\(m3mcpDefaultPort)")!,
        URL(string: "http://[::1]:\(m3mcpDefaultPort)")!
    ]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func call(tool: String, arguments: [String: Any]) async -> ToolResponse {
        var lastError: Error?

        for baseURL in baseURLs {
            do {
                return try await call(baseURL: baseURL, tool: tool, arguments: arguments)
            } catch {
                lastError = error
            }
        }

        return ToolResponse(
            ok: false,
            source: "M3MCPBridge",
            message: "M3MCPApp is not reachable. Start the macOS UI app first. \(lastError?.localizedDescription ?? "No local endpoint responded.")"
        )
    }

    private func call(baseURL: URL, tool: String, arguments: [String: Any]) async throws -> ToolResponse {
        let url = baseURL.appendingPathComponent("tools").appendingPathComponent(tool)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: arguments, options: [])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<500).contains(http.statusCode) {
            return ToolResponse(ok: false, source: "M3MCPBridge", message: "Local app returned HTTP \(http.statusCode).")
        }

        return try M3JSON.makeDecoder().decode(ToolResponse.self, from: data)
    }
}
