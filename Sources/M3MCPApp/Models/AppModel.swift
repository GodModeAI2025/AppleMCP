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

    @Published var destination: AppDestination = .overview
    @Published var showsSetup = false
    @Published private(set) var usageRiskAccepted: Bool
    private let preferences: UserDefaults
    private static let usageRiskVersion = 1
    private static let usageRiskKey = "m3mcp.setup.usageRisk.acceptedVersion"
    @Published private(set) var copyMessage: String?
    @Published private(set) var checkingConnection = false
    @Published private(set) var connectionVerified: Bool?
    @Published private(set) var connectionMessage: String?
    @Published private(set) var permissionBusy = false
    @Published private(set) var permissionProgress: String?
    @Published private(set) var permissionSequenceRunning = false
    private var stopPermissionSequence = false
    private let nativePermissions = PermissionProvider()
    private var permissionPresentation = NativePermissionPresentation()
    private var permissionRefreshGeneration = UUID()
    var permissionRestartRequired: Bool {
        permissionItems.contains { $0.metadata["restart_required"] == "true" }
    }
    private var clipboardCleanup: Task<Void, Never>?
    private var connectionGeneration = UUID()

    var hasCapabilityToken: Bool { capabilityToken != nil }
    var tokenForDisplay: String { capabilityToken ?? "" }
    var bridgeURL: URL {
        TrustedClient.bridgeURL(appExecutableURL: Bundle.main.executableURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/M3MCPApp"))
    }
    var requiresStoreSelection: Bool { TrustedClient.usesSandboxedHelper }

    func acceptStoreSelection(_ result: Result<[URL], Error>, for store: SandboxStoreAccess.Store) async {
        guard requiresStoreSelection else { return }
        do {
            guard let url = try result.get().first else { return }
            try SandboxStoreAccess.shared.install(url, for: store)
            permissionMessage = String(localized: "Ordnerfreigabe gespeichert. LocalMCP liest diesen Ordner mit deiner Freigabe.")
            await refreshPermissions()
        } catch { permissionMessage = error.localizedDescription }
    }

    var bridgeAvailable: Bool { FileManager.default.isExecutableFile(atPath: bridgeURL.path) }
    var enabledToolCount: Int { securityPolicy.toolAvailability.filter(\.isEnabled).count }

    let securityPolicy: M3MCPSecurityPolicy
    private let approvalCoordinator: NativeToolApprovalCoordinator
    private let service: LocalMCPService
    private let startupCleanupTask = AppStartupCleanupTask()
    private var server: LocalHTTPServer?

    /// Held so the Server menu can put it on the pasteboard. It never goes into an activity entry,
    /// into `/health`, or into a log line.
    private var capabilityToken: String?

    init(securityPolicy: M3MCPSecurityPolicy = .fromProcessEnvironment(), preferences: UserDefaults = .standard) {
        self.preferences = preferences
        usageRiskAccepted = preferences.integer(forKey: Self.usageRiskKey) == Self.usageRiskVersion
        let approvalCoordinator = NativeToolApprovalCoordinator()
        self.securityPolicy = securityPolicy
        self.approvalCoordinator = approvalCoordinator
        self.service = LocalMCPService(
            securityPolicy: securityPolicy,
            approvalHandler: { request in
                await approvalCoordinator.requestApproval(for: request)
            }
        )
        services = service.services
        selectedServiceName = services.first?.name

        AppLogger.log("AppModel init")
    }

    /// Records an explicit native setup confirmation. This grants no macOS permissions or tool opt-ins.
    func acceptUsageRisk() {
        preferences.set(Self.usageRiskVersion, forKey: Self.usageRiskKey)
        usageRiskAccepted = true
    }

    func startIfNeeded() {
        guard usageRiskAccepted else {
            showsSetup = true
            return
        }
        guard server == nil else { return }
        if let message = M3MCPEndpoint.configurationError {
            serverState = "failed"
            authenticationSummary = "unavailable"
            record(tool: "server_start", response: ToolResponse(ok: false,
                source: "LocalMCP Server", message: message), durationMilliseconds: 0)
            return
        }
        serverState = "starting"

        // Fail closed. If the token cannot be read or created the server does not come up at all:
        // starting it without one would put the endpoint back where it was before this existed,
        // reachable by every process of the user.
        let credentials: CapabilityToken.Resolution
        do {
            credentials = try CapabilityToken.loadOrCreate()
        } catch {
            serverState = "failed"
            let message = String(localized: "Der Server bleibt ohne MCP-Token geschlossen: \(error.localizedDescription). Bitte den Mac entsperren und die App erneut starten. Bleibt der Fehler bestehen, prüfe die installierte App-Version und ihre Signatur.")
            authenticationSummary = "unavailable"
            AppLogger.log(message)
            record(
                tool: "server_start",
                response: ToolResponse(ok: false, source: "LocalMCP Server", message: message),
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
                // A disconnected bridge cancels the connection task. Do not make slot recovery wait
                // for UI bookkeeping, and do not retain request details for an abandoned call.
                if !Task.isCancelled {
                    await MainActor.run {
                        self?.record(tool: tool, input: input, response: response, durationMilliseconds: elapsed)
                    }
                }
                return response
            },
            statusHandler: { [weak self] includeActivity in
                await MainActor.run {
                    self?.statusResponse(includeActivity: includeActivity) ?? StatusResponse(
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
                // and one line per accepted request would bury it.
                guard !attempt.allowed else { return }
                AppLogger.log("Refused \(attempt.method) \(attempt.path) from \(attempt.peer.description)")
                Task { @MainActor in
                    self?.record(
                        tool: "access_refused",
                        response: ToolResponse(
                            ok: false,
                            source: "LocalMCP Server",
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
            services = service.services + [authenticationService(authorizer)]
            record(
                tool: "server_start",
                response: ToolResponse(ok: true, source: "LocalMCP Server", message: "Listening on \(M3MCPEndpoint.displayPath)"),
                durationMilliseconds: 0
            )
        } catch {
            serverState = "failed"
            AppLogger.log("Local server failed: \(error.localizedDescription)")
            record(
                tool: "server_start",
                response: ToolResponse(ok: false, source: "LocalMCP Server", message: error.localizedDescription),
                durationMilliseconds: 0
            )
        }

        // Socket startup is attempted first. Cleanup is a single, retained application-lifecycle
        // utility task, not synchronous MainActor work or a side effect of a read-only provider.
        startupCleanupTask.startIfNeeded()
    }

    /// The one row in the service list that describes the endpoint's own door rather than a data
    /// source. `/health` carries it too, so a degraded install is visible from outside the app.
    private func authenticationService(_ authorizer: SocketAuthorizer) -> ServiceHealth {
        ServiceHealth(
            name: "Client Authentication",
            endpoint: "m3mcp://auth",
            mode: "capability token + peer code identity",
            state: authorizer.pinningDescription
        )
    }

    /// Puts the token on the pasteboard so it can go into an MCP client config. Returns what to show
    /// the user; the token itself never appears in a log or in a status reply.
    @discardableResult
    func copyCapabilityToken() -> String {
        guard let capabilityToken else {
            return String(localized: "The server is not running, so there is no token to copy.")
        }
        copySensitiveText(capabilityToken)
        copyMessage = String(localized: "Token kopiert. Jetzt im MCP-Client als M3MCP_TOKEN einfügen.")
        return copyMessage!
    }

    func configurationPreview(format: ClientConfiguration.Format) -> String {
        (try? ClientConfiguration.render(format: format, bridgePath: bridgeURL.path,
            token: "<MCP_TOKEN>", policy: securityPolicy)) ?? String(localized: "Konfiguration nicht verfügbar.")
    }

    func copyClientConfiguration(format: ClientConfiguration.Format) {
        guard let capabilityToken, bridgeAvailable else {
            copyMessage = String(localized: "Bitte zuerst den Server starten und die vollständige App verwenden.")
            return
        }
        do {
            let text = try ClientConfiguration.render(format: format, bridgePath: bridgeURL.path,
                token: capabilityToken, policy: securityPolicy)
            copySensitiveText(text)
            copyMessage = String(localized: "Konfiguration inklusive Token kopiert. Im Client einfügen und die Verbindung neu starten.")
        } catch {
            copyMessage = String(localized: "Die Konfiguration konnte nicht erstellt werden.")
        }
    }

    private func copySensitiveText(_ text: String) {
        clipboardCleanup?.cancel()
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        // Keep credentials out of Universal Clipboard and password-manager clipboard history.
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.localOnly"))
        let generation = board.changeCount
        clipboardCleanup = Task { @MainActor in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, board.changeCount == generation else { return }
            board.clearContents()
            self.copyMessage = nil
        }
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func checkConnection() async {
        guard !checkingConnection else { return }
        guard hasCapabilityToken, serverState == "running", bridgeAvailable else {
            connectionVerified = false
            connectionMessage = String(localized: "Server starten und prüfen, ob die MCP-Bridge im App-Paket vorhanden ist.")
            return
        }
        checkingConnection = true
        connectionVerified = nil
        connectionMessage = String(localized: "App und Bridge prüfen die Anmeldung …")
        let generation = connectionGeneration
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in ClientConfiguration.environment(token: capabilityToken!, policy: securityPolicy) {
            environment[key] = value
        }
        let ok = await ConnectionCheck.run(bridge: bridgeURL, environment: environment)
        checkingConnection = false
        guard generation == connectionGeneration else { return }
        connectionVerified = ok
        connectionMessage = ok
            ? String(localized: "Lokale Verbindung bestätigt: Die mitgelieferte Bridge wird mit deinem Token akzeptiert.")
            : String(localized: "Verbindung fehlgeschlagen: \(ConnectionCheck.diagnostic ?? String(localized: "Server neu starten und App sowie Bridge aus derselben Installation verwenden."))")
    }

    func checkSourceAccess(_ source: String) async -> String {
        guard usageRiskAccepted, serverState == "running" else { return String(localized: "Bitte zuerst den lokalen Server starten.") }
        let tool: String
        switch source {
        case "Calendar": tool = "calendar_list_calendars"
        case "Contacts / Address Book": tool = "contacts_search"
        case "Reminders": tool = "reminders_search"
        case "Notes": tool = "notes_search"
        case "Photos": tool = "photos_albums"
        default: return String(localized: "Für diese Quelle ist keine Zugriffsprüfung verfügbar.")
        }
        var input: [String: JSONValue] = source == "Calendar" ? [:] : ["limit": .number(1)]
        if source == "Notes" || source == "Reminders" { input["max_candidates"] = .number(10) }
        if source == "Notes" { input["include_body"] = .bool(false) }
        let response = await service.handle(tool: tool, input: input)
        return response.ok
            ? String(localized: "Zugriff erfolgreich: Abfrage ausgeführt (\(response.items.count) Ergebnisse innerhalb des Prüflimits). Es wurden keine Daten verändert.")
            : String(localized: "Zugriff fehlgeschlagen: \(response.message ?? String(localized: "Unbekannter Fehler"))")
    }

    func requestDataPermissions() async {
        await runDataPermissionSequence(performStep: { id in
            if id == "mail_local_store" || id == "voice_memos_store" {
                if requiresStoreSelection {
                    let store: SandboxStoreAccess.Store = id == "mail_local_store" ? .mail : .voiceMemos
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = String(localized: "Lesen erlauben")
                    panel.message = String(localized: store.instruction)
                    let response = await withCheckedContinuation { continuation in
                        panel.begin { response in continuation.resume(returning: response) }
                    }
                    if response == .OK, let url = panel.url {
                        await acceptStoreSelection(.success([url]), for: store)
                    }
                }
            } else {
                await performPermissionRequest(id: id)
            }
        }, refresh: { await self.refreshPermissions() })
    }

    /// The whole sequence owns the busy state, including user-controlled folder dialogs.
    /// Injected effects let tests verify ordering and cancellation without requesting real rights.
    func runDataPermissionSequence(
        performStep: (String) async -> Void,
        refresh: () async -> Void
    ) async {
        guard !permissionBusy else { return }
        permissionBusy = true
        permissionSequenceRunning = true
        stopPermissionSequence = false
        defer { permissionBusy = false; permissionSequenceRunning = false }
        let steps: [(String, LocalizedStringResource)] = [
            ("calendar", "Kalender"), ("contacts", "Kontakte"), ("reminders", "Erinnerungen"),
            ("mail_local_store", "Mail"), ("notes_automation", "Notizen"), ("photos", "Fotos"),
            ("voice_memos_store", "Sprachmemos"), ("speech_recognition", "Spracherkennung")
        ]
        for (index, step) in steps.enumerated() {
            guard !Task.isCancelled, !stopPermissionSequence else { break }
            permissionProgress = String(localized: "Schritt \(index + 1) von 8: \(String(localized: step.1))")
            await performStep(step.0)
        }
        await refresh()
        permissionProgress = stopPermissionSequence || Task.isCancelled
            ? String(localized: "Ablauf beendet. Bereits erteilte Freigaben bleiben erhalten.")
            : String(localized: "Alle acht Quellen durchlaufen. Prüfe unten die Ergebnisse. Fehlende Freigaben und Festplattenvollzugriff müssen gegebenenfalls in den Systemeinstellungen aktiviert werden.")
    }

    func cancelPermissionSequence() {
        // A macOS consent dialog belongs to the user; finish that dialog before stopping.
        stopPermissionSequence = true
        permissionProgress = String(localized: "Der Ablauf endet nach dem aktuellen Dialog.")
    }

    func processLocalText(_ text: String, style: String) async -> ToolResponse {
        guard usageRiskAccepted, serverState == "running" else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: String(localized: "Bitte zuerst die Einrichtung abschließen und den lokalen Server starten."))
        }
        return await service.handle(tool: "ai_summarize", input: ["text": .string(text), "style": .string(style)])
    }

    func stop() {
        connectionGeneration = UUID()
        connectionVerified = nil
        connectionMessage = nil
        copyMessage = nil
        server?.stop()
        server = nil
        serverState = "stopped"
        capabilityToken = nil
        authenticationSummary = "not started"
        services = service.services
        record(
            tool: "server_stop",
            response: ToolResponse(ok: true, source: "LocalMCP Server", message: "Stopped"),
            durationMilliseconds: 0
        )
    }

    func restart() {
        stop()
        startIfNeeded()
    }

    /// Native, deliberate clicks can request permissions even when remote permission tools are
    /// disabled. The remote LocalMCPService policy remains immutable and unchanged.
    func requestPermissions() async {
        guard !permissionBusy else { return }
        permissionBusy = true
        defer { permissionBusy = false }
        permissionRefreshGeneration = UUID()
        let result = await nativePermissions.requestAll()
        permissionRefreshGeneration = UUID()
        for item in result.items { permissionPresentation.received(item) }
        await refreshPermissions()
    }

    func requestPermission(id: String) async {
        guard !permissionBusy else { return }
        permissionBusy = true
        defer { permissionBusy = false }
        await performPermissionRequest(id: id)
    }

    private func performPermissionRequest(id: String) async {
        permissionRefreshGeneration = UUID()
        let result = await nativePermissions.requestFromNativeUI(id: id)
        permissionRefreshGeneration = UUID()
        if let result { permissionPresentation.received(result) }
        await refreshPermissions()
    }

    func refreshPermissions() async {
        permissionRefreshGeneration = UUID()
        let generation = permissionRefreshGeneration
        let response = await service.handle(tool: "permissions_status", input: [:])
        guard generation == permissionRefreshGeneration else { return }
        permissionItems = permissionPresentation.reconcile(response.items)
        permissionMessage = response.message
    }

    func restartApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Preserve explicit launch opt-ins. The token remains in the keychain, never in arguments.
        configuration.environment = ProcessInfo.processInfo.environment
        stop()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if error != nil {
                    self.permissionMessage = String(localized: "Die App konnte nicht neu geöffnet werden. Bitte LocalMCP mit ⌘Q beenden und erneut öffnen.")
                    self.startIfNeeded()
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    func openPermissionSettings(pane: String) {
        let response = nativePermissions.openSettings(input: ["pane": .string(pane)])
        if !response.ok { permissionMessage = String(localized: "Die Systemeinstellungen konnten nicht geöffnet werden.") }
    }

    func statusResponse(includeActivity: Bool = true) -> StatusResponse {
        StatusResponse(
            ok: serverState == "running",
            version: m3mcpVersion,
            endpoint: M3MCPEndpoint.socketURL.path,
            services: services,
            recentActivity: includeActivity ? Array(activity.prefix(30)) : []
        )
    }

    private func record(tool: String, input: [String: JSONValue] = [:], response: ToolResponse, durationMilliseconds: Int) {
        let inputJSON: String? = {
            guard !input.isEmpty else { return nil }
            let wrapped = JSONValue.object(input)
            guard let data = try? JSONEncoder().encode(wrapped),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let limit = 8_000
            return text.count <= limit ? text : String(text.prefix(limit)) + "\n[activity input truncated]"
        }()

        let outputJSON: String? = {
            guard let data = try? JSONEncoder().encode(response),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let limit = 8_000
            return text.count <= limit ? text : String(text.prefix(limit)) + "\n[activity output truncated]"
        }()

        let entry = ActivityEntry(
            endpoint: endpoint(for: tool),
            provider: response.source,
            status: response.ok ? "ok" : "error",
            detail: response.ok
                ? String(localized: "\(response.items.count) Ergebnisse")
                : String((response.message ?? "error").prefix(2_000)),
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
