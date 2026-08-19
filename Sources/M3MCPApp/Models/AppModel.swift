import AppKit
import Foundation
import M3MCPCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var services: [ServiceHealth] = []
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var permissionItems: [DataItem] = []
    @Published private(set) var permissionMessage: String?
    @Published private(set) var serverState = "stopped"
    @Published var selectedServiceName: String?

    private let service = LocalMCPService()
    private var server: LocalHTTPServer?

    init() {
        services = service.services
        selectedServiceName = services.first?.name
        AppLogger.log("AppModel init")
    }

    func startIfNeeded() {
        guard server == nil else { return }
        serverState = "starting"

        let localService = service
        let server = LocalHTTPServer(
            socketURL: M3MCPEndpoint.socketURL,
            toolHandler: { [weak self] tool, input in
                let started = Date()
                let response = await localService.handle(tool: tool, input: input)
                let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
                await MainActor.run {
                    self?.record(tool: tool, input: input, response: response, durationMilliseconds: elapsed)
                }
                return response
            },
            statusHandler: { [weak self] in
                await MainActor.run {
                    self?.statusResponse() ?? StatusResponse(
                        ok: false,
                        version: m3mcpVersion,
                        endpoint: M3MCPEndpoint.socketURL.path,
                        services: [],
                        recentActivity: []
                    )
                }
            }
        )

        do {
            try server.start()
            self.server = server
            serverState = "running"
            AppLogger.log("Local server listening on \(M3MCPEndpoint.socketURL.path)")
            services = service.services
            record(
                tool: "server_start",
                response: ToolResponse(ok: true, source: "M3MCP Server", message: "Listening on \(M3MCPEndpoint.displayPath)"),
                durationMilliseconds: 0
            )
        } catch {
            serverState = "failed"
            AppLogger.log("Local server failed: \(error.localizedDescription)")
            record(
                tool: "server_start",
                response: ToolResponse(ok: false, source: "M3MCP Server", message: error.localizedDescription),
                durationMilliseconds: 0
            )
        }
    }

    func stop() {
        server?.stop()
        server = nil
        serverState = "stopped"
        record(
            tool: "server_stop",
            response: ToolResponse(ok: true, source: "M3MCP Server", message: "Stopped"),
            durationMilliseconds: 0
        )
    }

    func restart() {
        stop()
        startIfNeeded()
    }

    func requestPermissions() async {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let started = Date()
        let response = await service.handle(tool: "permissions_request", input: [:])
        permissionItems = response.items
        permissionMessage = response.message
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        record(tool: "permissions_request", response: response, durationMilliseconds: elapsed)
    }

    func refreshPermissions() async {
        let started = Date()
        let response = await service.handle(tool: "permissions_status", input: [:])
        permissionItems = response.items
        permissionMessage = response.message
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        record(tool: "permissions_status", response: response, durationMilliseconds: elapsed)
    }

    func openPermissionSettings(pane: String) {
        Task {
            let started = Date()
            let response = await service.handle(tool: "permissions_open_settings", input: ["pane": .string(pane)])
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            record(tool: "permissions_open_settings", response: response, durationMilliseconds: elapsed)
        }
    }

    func statusResponse() -> StatusResponse {
        StatusResponse(
            ok: serverState == "running",
            version: m3mcpVersion,
            endpoint: M3MCPEndpoint.socketURL.path,
            services: services,
            recentActivity: Array(activity.prefix(30))
        )
    }

    private func record(tool: String, input: [String: JSONValue] = [:], response: ToolResponse, durationMilliseconds: Int) {
        let inputJSON: String? = {
            guard !input.isEmpty else { return nil }
            let wrapped = JSONValue.object(input)
            guard let data = try? JSONEncoder().encode(wrapped),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }()

        let outputJSON: String? = {
            guard let data = try? JSONEncoder().encode(response),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return String(text.prefix(8_000))
        }()

        let entry = ActivityEntry(
            endpoint: endpoint(for: tool),
            provider: response.source,
            status: response.ok ? "ok" : "error",
            detail: response.ok ? "\(response.items.count) item(s)" : (response.message ?? "error"),
            durationMilliseconds: durationMilliseconds,
            toolName: tool,
            inputJSON: inputJSON,
            outputJSON: outputJSON
        )
        activity.insert(entry, at: 0)
        if activity.count > 100 {
            activity.removeLast(activity.count - 100)
        }
    }

    private func endpoint(for tool: String) -> String {
        switch tool {
        case "calendar_search": return "eventkit://events"
        case "contacts_search": return "contacts://local"
        case "mail_search", "mail_read": return "mail://local-index"
        case "permissions_status", "permissions_request", "permissions_open_settings": return "m3mcp://permissions"
        case "reminders_search": return "eventkit://reminders"
        case "notes_search", "notes_read": return "macos://Notes.app"
        case "photos_search", "photos_albums": return "photos://library"
        case "voicememos_search", "voicememos_read", "voicememos_transcript", "voicememos_audio", "voicememos_transcribe":
            return "voicememos://local-store"
        case "ai_writing_tools", "ai_translate", "ai_image_playground": return "macos://intelligence"
        case "ai_summarize": return "macos://foundationmodels"
        case "source_status": return "m3mcp://status"
        default: return "m3mcp://tools/\(tool)"
        }
    }

}
