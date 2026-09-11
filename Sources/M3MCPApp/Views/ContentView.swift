import M3MCPCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("m3mcp.setup.v1.completed") private var setupCompleted = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            SidebarView(services: model.services, destination: $model.destination,
                        running: model.serverState == "running", onSetup: { model.showsSetup = true })
                .navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 260)
        } detail: {
            VStack(spacing: 0) {
                AppHeader(model: model)
                Divider()
                ScrollView {
                    DestinationView(model: model)
                        .padding(30)
                        .frame(maxWidth: 1080)
                        .frame(maxWidth: .infinity)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .tint(.indigo)
        .sheet(isPresented: $model.showsSetup) {
            SetupAssistant(model: model) { setupCompleted = true }
        }
        .task {
            model.startIfNeeded()
            if !setupCompleted || !model.usageRiskAccepted { model.showsSetup = true }
            await model.refreshPermissions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshPermissions() } }
        }
    }
}

private struct DestinationView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch model.destination {
            case .overview: OverviewView(model: model)
            case .connection: ConnectionView(model: model)
            case .permissions: PermissionsView(model: model)
            case .activity: ActivityPage(activity: model.activity)
            case .source(let name): SourcePage(name: name, model: model)
            }
        }
    }
}

private struct AppHeader: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            StatusPill(text: model.serverState == "running" ? "Server läuft" : "Server nicht aktiv",
                       symbol: model.serverState == "running" ? "checkmark.circle.fill" : "pause.circle",
                       good: model.serverState == "running")
            Spacer(minLength: 10)
            Button { model.destination = .connection } label: {
                Label("MCP-Token & Verbindung", systemImage: "key.horizontal")
            }
            Button { model.showsSetup = true } label: {
                Label("Einrichten", systemImage: "wand.and.stars")
            }
            Menu {
                Button("Server starten", action: model.startIfNeeded).disabled(model.serverState == "running")
                Button("Server neu starten", action: model.restart)
                Button("Server stoppen", action: model.stop).disabled(model.serverState == "stopped")
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Server steuern")
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }
}
