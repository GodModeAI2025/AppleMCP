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
    @Published private(set) var authenticationSummary = "not started"
    @Published var selectedServiceName: String?

    private let service = LocalMCPService()
    private var server: LocalHTTPServer?

    /// Held so the Server menu can put it on the pasteboard. It never goes into an activity entry,
    /// into `/health`, or into a log line.
    private var capabilityToken: String?

    init() {
        services = service.services
        selectedServiceName = services.first?.name
        AppLogger.log("AppModel init")
    }

    func startIfNeeded() {
        guard server == nil else { return }
        serverState = "starting"

        // Fail closed. If the token cannot be read or created the server does not come up at all:
        // starting it without one would put the endpoint back where it was before this existed,
        // reachable by every process of the user.
        let credentials: CapabilityToken.Resolution
        do {
            credentials = try CapabilityToken.loadOrCreate()
        } catch {
            serverState = "failed"
            let message = "No capability token, so the endpoint stays closed: \(error.localizedDescription). "
                + "Unlock the login keychain and start again, or set \(CapabilityToken.environmentKey) "
                + "for this run."
            authenticationSummary = "unavailable"
            AppLogger.log(message)
            record(
                tool: "server_start",
                response: ToolResponse(ok: false, source: "M3MCP Server", message: message),
                durationMilliseconds: 0
            )
            return
        }

        let trust = TrustedClient.resolve(appExecutableURL: Bundle.main.executableURL)
        let authorizer = SocketAuthorizer(
            token: credentials.token,
            trustedCodeDirectoryHashes: trust.hashes,
            trustDescription: trust.note
        )
        capabilityToken = credentials.token
        authenticationSummary = "\(authorizer.pinningDescription); token from \(credentials.origin)"
        AppLogger.log("Client authentication: \(trust.note)")

        let localService = service
        let server = LocalHTTPServer(
            socketURL: M3MCPEndpoint.socketURL,
            authorizer: authorizer,
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
            },
            auditHandler: { [weak self] attempt in
                // Only refusals are recorded. A granted call is already an activity entry of its own,
                // and one line per accepted connection would bury it.
                guard !attempt.allowed else { return }
                AppLogger.log("Refused \(attempt.method) \(attempt.path) from \(attempt.peer.description)")
                Task { @MainActor in
                    self?.record(
                        tool: "access_refused",
                        response: ToolResponse(
                            ok: false,
                            source: "M3MCP Server",
                            message: attempt.reason ?? "Refused",
                            meta: [
                                "path": attempt.path,
                                "method": attempt.method,
                                "peer_pid": String(attempt.peer.processIdentifier),
                                "peer_identifier": attempt.peer.signingIdentifier ?? "",
                                "peer_cdhash": attempt.peer.codeDirectoryHash ?? "",
                                "peer_path": attempt.peer.executablePath ?? ""
                            ]
                        ),
                        durationMilliseconds: 0
                    )
                }
            }
        )

        do {
            try server.start()
            self.server = server
            serverState = "running"
            AppLogger.log("Local server listening on \(M3MCPEndpoint.socketURL.path)")
            services = service.services + [
                ServiceHealth(
                    name: "Client Authentication",
                    endpoint: "m3mcp://auth",
                    mode: "capability token + peer code identity",
                    state: authorizer.pinningDescription
                )
            ]
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
        capabilityToken = nil
        authenticationSummary = "not started"
        services = service.services
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

    /// Puts the token on the pasteboard so it can go into an MCP client config. Returns what to show
    /// the user; the token itself never appears in a log or in a status reply.
    @discardableResult
    func copyCapabilityToken() -> String {
        guard let capabilityToken else {
            return "The server is not running, so there is no token to copy."
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(capabilityToken, forType: .string)
        return "Capability token copied. Put it in your MCP client config as "
            + "\"env\": {\"\(CapabilityToken.environmentKey)\": \"…\"}."
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
