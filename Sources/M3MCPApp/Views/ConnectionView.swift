import M3MCPCore
import SwiftUI

struct ConnectionView: View {
    @ObservedObject var model: AppModel
    var compact = false
    @State private var format: ClientConfiguration.Format = .codex
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !compact {
                PageHeading(title: "Deine Verbindung", subtitle: "Token kopieren, Client einrichten und die lokale Verbindung prüfen.")
            }
            TokenPanel(model: model)
            Panel {
                Label("Client-Konfiguration", systemImage: "curlybraces").font(.title3.weight(.semibold))
                Picker("MCP-Client", selection: $format) {
                    Text("Codex · TOML").tag(ClientConfiguration.Format.codex)
                    Text("Andere Clients · JSON").tag(ClientConfiguration.Format.json)
                }.pickerStyle(.segmented)
                ConfigurationInstructions(format: format)
                DisclosureGroup("Konfiguration ansehen · Token ausgeblendet") {
                    ScrollView(.horizontal) {
                        Text(model.configurationPreview(format: format))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                Button { model.copyClientConfiguration(format: format) } label: {
                    Label("Konfiguration inklusive Token kopieren", systemImage: "doc.on.doc")
                }.buttonStyle(.borderedProminent).disabled(!model.hasCapabilityToken || !model.bridgeAvailable)
                Text("Die Vorschau verbirgt den Token. Der Kopierknopf setzt den echten Token und den aktuellen App-Pfad ein.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Manuelle Einrichtung") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transport: STDIO / lokaler Befehl").font(.callout.weight(.medium))
                        Text(model.bridgeURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("Umgebungsvariable: M3MCP_TOKEN. Als Wert den oben kopierten Token einfügen.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }
            ConnectionCheckPanel(model: model)
        }
    }
}

private struct TokenPanel: View {
    @ObservedObject var model: AppModel
    @State private var revealToken = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Panel {
            HStack(spacing: 14) {
                FeatureIcon(symbol: "key.horizontal.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dein MCP-Token").font(.title2.weight(.semibold))
                    Text("Der Schlüssel für die Verbindung mit dieser App.").foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: model.hasCapabilityToken ? "Verfügbar" : "Server starten",
                           symbol: model.hasCapabilityToken ? "checkmark.circle" : "exclamationmark.circle", good: model.hasCapabilityToken)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("M3MCP_TOKEN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if revealToken && model.hasCapabilityToken {
                        Text(model.tokenForDisplay).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).privacySensitive()
                    } else {
                        Text(model.hasCapabilityToken ? "••••••••  ••••••••  ••••••••" : "Nach dem Serverstart verfügbar")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                Spacer(minLength: 0)
                Button { revealToken.toggle() } label: {
                    Label(revealToken ? "Verbergen" : "Anzeigen", systemImage: revealToken ? "eye.slash" : "eye")
                }.disabled(!model.hasCapabilityToken)
            }
            .padding(16).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Button { model.copyCapabilityToken() } label: {
                    Label("MCP-Token kopieren", systemImage: "doc.on.doc.fill")
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.hasCapabilityToken)
                if !model.hasCapabilityToken {
                    Button("Server starten", action: model.startIfNeeded)
                }
            }
            if let message = model.copyMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.indigo).accessibilityAddTraits(.updatesFrequently)
            }
            Text("Nur im gewünschten MCP-Client einfügen. Nicht in Chats teilen. Die Zwischenablage wird nach 90 Sekunden geleert, sofern du nichts anderes kopiert hast.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { revealToken = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { revealToken = false } }
        .onChange(of: model.hasCapabilityToken) { _, available in if !available { revealToken = false } }
        .task(id: revealToken) {
            if revealToken {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { revealToken = false }
            }
        }
    }
}

private struct ConfigurationInstructions: View {
    let format: ClientConfiguration.Format
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if format == .codex {
                Text("1. Konfiguration mit dem Knopf unten kopieren.")
                Text("2. In ~/.codex/config.toml den M3MCP-Abschnitt ergänzen oder den vorhandenen M3MCP-Eintrag ersetzen. Andere Server beibehalten.")
                Text("3. Die MCP-Verbindung im Client neu laden; falls nötig, den Client neu starten.")
                Link("Offizielle Codex-Anleitung", destination: URL(string: "https://developers.openai.com/codex/mcp")!)
                    .font(.caption)
            } else {
                Text("1. Konfiguration inklusive Token kopieren.")
                Text("2. Den Eintrag m3mcp in den mcpServers-Bereich deines Clients übernehmen. Vorhandene andere Server beibehalten.")
                Text("3. Speichern und die MCP-Verbindung neu laden.")
            }
        }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct ConnectionCheckPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Panel {
            HStack {
                Label("Verbindung prüfen", systemImage: "checkmark.shield").font(.title3.weight(.semibold))
                Spacer()
                if model.checkingConnection { ProgressView().controlSize(.small) }
                else if let verified = model.connectionVerified {
                    StatusPill(text: verified ? "Lokal bestätigt" : "Prüfung fehlgeschlagen",
                               symbol: verified ? "checkmark.circle.fill" : "exclamationmark.triangle", good: verified)
                }
            }
            Text("Prüft die mitgelieferte Bridge, den Token und die Anmeldung am laufenden Server. Persönliche Inhalte werden dabei nicht gelesen.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = model.connectionMessage {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Button { Task { await model.checkConnection() } } label: {
                Label(model.checkingConnection ? "Verbindung wird geprüft …" : "Lokale Verbindung testen", systemImage: "arrow.triangle.2.circlepath")
            }.disabled(model.checkingConnection)
            Text("Dieser Test bestätigt die lokale App-Verbindung. Ob dein externer Client eingerichtet ist, prüfst du dort mit einer ersten Anfrage.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
