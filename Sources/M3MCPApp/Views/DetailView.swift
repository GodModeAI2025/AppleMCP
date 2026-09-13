import M3MCPCore
import SwiftUI
import AppKit
import ImagePlayground

struct SourcePage: View {
    let name: String
    @ObservedObject var model: AppModel
    @State private var sourceCheckMessage: String?
    @State private var checkingSource = false
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
                Text("Stelle deine Frage im verbundenen MCP-Client. LocalMCP führt die unterstützte Abfrage auf diesem Mac aus.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Verbindung einrichten") { model.destination = .connection }
                        .buttonStyle(.borderedProminent)
                    Button("Freigaben verwalten") { model.destination = .permissions }
                }
            }
            if ["Calendar", "Contacts / Address Book", "Reminders", "Notes", "Photos"].contains(name) {
                Panel {
                    Text("Datenzugriff prüfen").font(.headline)
                    Text("Führt eine begrenzte Leseabfrage aus und zeigt nur den Ergebnisstatus. Inhalte werden hier nicht angezeigt oder verändert.")
                        .foregroundStyle(.secondary)
                    Button("Zugriff jetzt prüfen") {
                        checkingSource = true
                        sourceCheckMessage = nil
                        Task { @MainActor in
                            sourceCheckMessage = await model.checkSourceAccess(name)
                            checkingSource = false
                        }
                    }.disabled(checkingSource)
                    if let sourceCheckMessage { Text(sourceCheckMessage).textSelection(.enabled) }
                }
            }
            if name == "Apple Intelligence" {
                Panel {
                    Text("Bilderzeugung und Kurzbefehle").font(.headline)
                    Text(AppleIntelligenceProvider.imageCreationStatusDescription)
                        .foregroundStyle(.secondary)
                }
                if #available(macOS 27, *) {
                    AppleCloudImagePanel(enabled: model.usageRiskAccepted)
                }
            }
            if name == "Foundation Models" {
                LocalTextToolsView { text, style in
                    await model.processLocalText(text, style: style)
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


@available(macOS 27, *)
private struct AppleCloudImagePanel: View {
    let enabled: Bool
    @Environment(\.supportsImagePlayground) private var supported
    @State private var concept = ""
    @State private var presented = false
    @State private var resultURL: URL?
    @State private var preview: NSImage?
    @State private var message: String?

    private var options: ImagePlaygroundOptions {
        var options = ImagePlaygroundOptions()
        options.personalization = .disabled
        return options
    }

    var body: some View {
        Panel {
            Text("Bild mit Apple Cloud erstellen").font(.headline)
            Text("Optional: Deine Bildbeschreibung wird an Apples Private Cloud Compute übermittelt. Diese Funktion arbeitet nicht offline. Im Apple-Dialog kannst du das Bild prüfen und übernehmen oder abbrechen.")
                .foregroundStyle(.secondary)
            TextField("Bildbeschreibung", text: $concept, axis: .vertical)
                .lineLimit(2...5)
            Button("Apple-Cloud-Bilddialog öffnen") {
                message = nil
                presented = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(!enabled || !supported || concept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || concept.count > 4_000)
            if !supported {
                Text("Image Playground ist auf diesem Mac derzeit nicht verfügbar. Prüfe Apple Intelligence in den Systemeinstellungen.")
                    .foregroundStyle(.secondary)
            }
            if concept.count > 4_000 {
                Text("Bitte kürze die Beschreibung auf höchstens 4.000 Zeichen.").foregroundStyle(.orange)
            }
            if let message { Text(message).textSelection(.enabled) }
            if let preview, let resultURL {
                Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 320)
                    .accessibilityLabel("Übernommenes Bild aus Apple Image Playground")
                Button("Bilddatei im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([resultURL])
                }
                Text("Die Datei liegt vorübergehend im App-Speicher. Kopiere sie zum dauerhaften Aufbewahren in einen eigenen Ordner.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .imagePlaygroundSheet(isPresented: $presented, concepts: [.text(concept)], onCompletion: acceptImage,
            onCancellation: { message = String(localized: "Bilderzeugung abgebrochen.") })
        .imagePlaygroundGenerationStyle(.illustration, in: [.illustration, .animation, .sketch])
        .imagePlaygroundOptions(options)
    }

    private func acceptImage(_ url: URL) {
        do {
            guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let maximum = 25 * 1_024 * 1_024
            let data = try handle.read(upToCount: maximum + 1) ?? Data()
            guard !data.isEmpty, data.count <= maximum, let image = NSImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "heic", "tiff"].contains(ext) else {
                throw CocoaError(.fileReadUnknown)
            }
            let saved = try PrivateTemporaryFile.write(data, prefix: "m3mcp-image-", suffix: "." + ext)
            resultURL = saved
            preview = image
            message = String(localized: "Bild aus dem Apple-Dialog übernommen.")
        } catch {
            message = String(localized: "Bild konnte nicht übernommen werden: \(error.localizedDescription)")
        }
    }
}
