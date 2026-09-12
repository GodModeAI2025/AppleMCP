import M3MCPCore
import SwiftUI

struct SidebarView: View {
    let services: [ServiceHealth]
    @Binding var destination: AppDestination
    let running: Bool
    let onSetup: () -> Void

    private var sources: [ServiceHealth] {
        services.filter { $0.name != "Permissions" && $0.name != "Client Authentication" }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title).foregroundStyle(.white).frame(width: 42, height: 42)
                    .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("LocalMCP").font(.title3.weight(.bold))
                    Text("Dein Mac. Verbunden.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(20)
            List(selection: $destination) {
                Section("Arbeitsbereich") {
                    Label("Übersicht", systemImage: "square.grid.2x2").tag(AppDestination.overview)
                    Label("Verbindung", systemImage: "key.horizontal").tag(AppDestination.connection)
                    Label("Freigaben", systemImage: "hand.raised").tag(AppDestination.permissions)
                    Label("Aktivität", systemImage: "clock.arrow.circlepath").tag(AppDestination.activity)
                }
                Section("Datenquellen") {
                    ForEach(sources) { service in
                        SourceNavigationRow(source: SourcePresentation.forName(service.name))
                            .tag(AppDestination.source(service.name))
                    }
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Button(action: onSetup) { Label("Einrichtungsassistent", systemImage: "wand.and.stars") }
                    .buttonStyle(.plain).foregroundStyle(.indigo)
                Label("Lokal auf diesem Mac", systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }
    }
}
private struct SourceNavigationRow: View {
    let source: SourcePresentation
    var body: some View { Label(source.title, systemImage: source.icon).padding(.vertical, 3) }
}
