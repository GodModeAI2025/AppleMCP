import M3MCPCore
import SwiftUI

struct SourcePage: View {
    let name: String
    @ObservedObject var model: AppModel
    private var presentation: SourcePresentation { SourcePresentation.forName(name) }
    private var tools: [M3MCPSecurityPolicy.ToolAvailability] {
        model.securityPolicy.toolAvailability.filter { $0.name.hasPrefix(presentation.prefix) }
    }
    private var granted: Bool {
        model.permissionItems.first { $0.id == presentation.permissionID }?.metadata["state"] == "authorized"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                FeatureIcon(symbol: presentation.icon)
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.title).font(.largeTitle.weight(.bold))
                    Text(presentation.description).foregroundStyle(.secondary)
                }
            }
            Panel {
                HStack {
                    Text("Zugriff auf diese Quelle").font(.headline)
                    Spacer()
                    if presentation.permissionID != nil {
                        StatusPill(text: granted ? "Freigegeben" : "Freigabe prüfen", symbol: granted ? "checkmark.circle" : "hand.raised", good: granted)
                    } else {
                        Text("Abhängig von macOS & Hardware").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Stelle deine Frage im verbundenen MCP-Client. M3MCP führt die unterstützte Abfrage auf diesem Mac aus.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Verbindung einrichten") { model.destination = .connection }
                        .buttonStyle(.borderedProminent)
                    Button("Freigaben verwalten") { model.destination = .permissions }
                }
            }
            Panel {
                Text("Verfügbare Werkzeuge").font(.headline)
                ForEach(tools) { tool in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.name).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            if !tool.isEnabled {
                                Text("Separat aktivierbare Zusatzfunktion").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(tool.isEnabled ? "Aktiv" : "Deaktiviert")
                            .font(.caption.weight(.medium)).foregroundStyle(tool.isEnabled ? Color.green : Color.secondary)
                    }.padding(.vertical, 6)
                }
            }
        }
    }
}

struct ActivityPage: View {
    let activity: [ActivityEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(title: "Letzte Aktivitäten", subtitle: "Anfragen und Serverereignisse dieser Sitzung. Neue Einträge stehen oben.")
            Panel {
                if activity.isEmpty {
                    ContentUnavailableView("Noch keine Anfragen", systemImage: "clock", description: Text("Nach deiner ersten MCP-Anfrage erscheint hier das Ergebnis."))
                } else {
                    ForEach(activity) { entry in
                        ActivityEntryView(entry: entry)
                        if entry.id != activity.last?.id { Divider() }
                    }
                }
            }
        }
    }
}
private struct ActivityEntryView: View {
    let entry: ActivityEntry
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.detail).font(.callout).textSelection(.enabled)
                if let input = entry.inputJSON {
                    Text("Eingabe").font(.caption.weight(.semibold))
                    Text(input).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let output = entry.outputJSON {
                    Text("Antwort").font(.caption.weight(.semibold))
                    Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.padding(.vertical, 10)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(entry.status == "ok" ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.toolName.isEmpty ? entry.endpoint : entry.toolName).font(.callout.weight(.medium))
                    Text(entry.provider).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.at, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                Text("\(entry.durationMilliseconds) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        }
    }
}
