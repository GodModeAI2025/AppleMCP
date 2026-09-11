import M3MCPCore
import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: AppModel
    private var granted: Int { model.permissionItems.filter { $0.metadata["state"] == "authorized" }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(title: "Alles verbunden. Alles im Blick.",
                        subtitle: "Deine Apple-Daten für deinen MCP-Client – mit Freigaben, die du kontrollierst.")
            WelcomePanel(onSetup: { model.showsSetup = true })
            HStack(alignment: .top, spacing: 14) {
                MetricCard(title: "Lokaler Server", value: model.serverState == "running" ? "Aktiv" : "Gestoppt", icon: "server.rack", note: "Auf diesem Mac")
                MetricCard(title: "Werkzeuge", value: "\(model.enabledToolCount)", icon: "square.stack.3d.up", note: "Im aktuellen Profil")
                MetricCard(title: "Freigaben", value: "\(granted) / \(model.permissionItems.count)", icon: "checkmark.shield", note: "Je nach Datenquelle")
            }
            Panel {
                HStack(alignment: .top, spacing: 16) {
                    FeatureIcon(symbol: "key.horizontal")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hier findest du deinen MCP-Token").font(.title3.weight(.semibold))
                        Text("Verbinde deinen Client mit dieser App. Token, passender App-Pfad und fertige Konfiguration stehen an einem Ort.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Verbindung einrichten") { model.destination = .connection }
                            .buttonStyle(.borderedProminent).padding(.top, 6)
                    }
                }
            }
            Panel {
                Text("Deine nächsten Schritte").font(.headline)
                OverviewStep(number: "1", title: "Daten freigeben", detail: "Mail und Sprachmemos benötigen Festplattenvollzugriff.", action: { model.destination = .permissions })
                Divider()
                OverviewStep(number: "2", title: "Client verbinden", detail: "Die Konfiguration mit Token in deinem MCP-Client einfügen.", action: { model.destination = .connection })
                Divider()
                OverviewStep(number: "3", title: "Eine Frage stellen", detail: "Zum Beispiel: „Zeige mir meine fünf neuesten Mails.“", action: { model.destination = .activity })
            }
        }
    }
}
private struct WelcomePanel: View {
    let onSetup: () -> Void
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("M3MCP FÜR MAC", systemImage: "desktopcomputer").font(.caption.weight(.semibold)).opacity(0.8)
                Text("Ein guter Start.\nIn wenigen Schritten.").font(.largeTitle.weight(.bold))
                Text("Der Assistent hilft dir bei Freigaben, Token und Verbindung.")
                    .font(.body).opacity(0.85).fixedSize(horizontal: false, vertical: true)
                Button("Einrichtungsassistent öffnen", action: onSetup)
                    .buttonStyle(.borderedProminent).tint(.white.opacity(0.2)).padding(.top, 6)
            }
            Spacer(minLength: 0)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 78, weight: .light)).foregroundStyle(.white.opacity(0.65))
                .padding(16).accessibilityHidden(true)
        }
        .foregroundStyle(.white).padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.18, green: 0.20, blue: 0.43), Color(red: 0.30, green: 0.25, blue: 0.60)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 22))
    }
}
private struct MetricCard: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    let note: LocalizedStringKey
    var body: some View {
        Panel {
            Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.largeTitle.weight(.semibold))
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}
private struct OverviewStep: View {
    let number: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(number).font(.headline).foregroundStyle(.indigo).frame(width: 30, height: 30)
                    .background(.indigo.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
