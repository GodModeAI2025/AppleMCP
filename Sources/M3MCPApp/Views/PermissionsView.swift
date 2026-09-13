import M3MCPCore
import SwiftUI
import UniformTypeIdentifiers

struct PermissionsView: View {
    @ObservedObject var model: AppModel
    var compact = false
    @State private var selectedStore: SandboxStoreAccess.Store = .mail
    @State private var showsStoreImporter = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !compact {
                PageHeading(title: "Deine Daten. Deine Freigaben.", subtitle: "Aktiviere die Quellen, die du mit deinem MCP-Client nutzen möchtest.")
            }
            Panel {
                HStack(alignment: .top, spacing: 14) {
                    FeatureIcon(symbol: "externaldrive.badge.person.crop")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mail & Sprachmemos").font(.title3.weight(.semibold))
                        if model.requiresStoreSelection {
                            Text("Wähle die beiden Datenordner ausdrücklich aus. LocalMCP speichert eine Lesefreigabe für diese App. macOS kann zusätzlich Festplattenvollzugriff verlangen.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Mail-Ordner auswählen") { selectedStore = .mail; showsStoreImporter = true }
                                Button("Sprachmemo-Ordner auswählen") { selectedStore = .voiceMemos; showsStoreImporter = true }
                            }.buttonStyle(.borderedProminent).disabled(model.permissionBusy)
                        }
                        Text(model.requiresStoreSelection
                             ? "Falls macOS den ausgewählten Datenordner weiterhin schützt, erlaube zusätzlich Festplattenvollzugriff für diese App und starte sie neu."
                             : "Für diese Quellen benötigt LocalMCP Festplattenvollzugriff. Öffne die Systemeinstellungen, füge diese App über + hinzu und aktiviere den Schalter. Danach LocalMCP mit ⌘Q beenden und erneut öffnen.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Festplattenvollzugriff öffnen") { model.openPermissionSettings(pane: "full_disk_access") }
                                .buttonStyle(.borderedProminent)
                            Button("App im Finder zeigen", action: model.revealApplication)
                        }
                    }
                }
            }
            Panel {
                Text("Datenfreigaben gemeinsam einrichten").font(.headline)
                Text("Führt durch Kalender, Kontakte, Erinnerungen, Mail, Notizen, Fotos, Sprachmemos und Spracherkennung. Du kannst jeden Dialog ablehnen oder die Ordnerauswahl abbrechen. Bereits entschiedene Freigaben zeigt macOS nicht erneut an.")
                    .foregroundStyle(.secondary)
                Button("Datenfreigaben nacheinander anfragen") {
                    Task { await model.requestDataPermissions() }
                }.disabled(model.permissionBusy)
                if let progress = model.permissionProgress {
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
                if model.permissionSequenceRunning {
                    Button("Nach aktuellem Dialog beenden", action: model.cancelPermissionSequence)
                }
            }
            if model.permissionRestartRequired {
                Panel {
                    Label("Freigabe bestätigt · Neustart erforderlich", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.green)
                    Text("macOS hat deine Freigabe bestätigt. Der bisherige Prozess meldet noch den alten Status. Starte die App neu, damit auch die Datenabfragen den neuen Zugriff verwenden.")
                        .foregroundStyle(.secondary)
                    Button("App neu starten", action: model.restartApplication).buttonStyle(.borderedProminent)
                }
            }
            HStack {
                Text("Zugriff pro Datenquelle").font(.headline)
                Spacer()
                if model.permissionBusy { ProgressView().controlSize(.small) }
                Button { Task { await model.refreshPermissions() } } label: {
                    Label("Status aktualisieren", systemImage: "arrow.clockwise")
                }.disabled(model.permissionBusy)
            }
            Panel {
                if model.permissionItems.isEmpty {
                    Text("Status wird ermittelt …").foregroundStyle(.secondary)
                }
                ForEach(model.permissionItems) { item in
                    PermissionAccessRow(item: item, busy: model.permissionBusy,
                        request: { Task { await model.requestPermission(id: item.id) } },
                        openSettings: model.openPermissionSettings,
                        chooseFolder: folderSelection(for: item.id))
                    if item.id != model.permissionItems.last?.id { Divider() }
                }
            }
            if let message = model.permissionMessage, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("Die App verwendet die auf diesem Mac eingerichteten Apple-Accounts. Eine zusätzliche iCloud-Anmeldung in LocalMCP ist nicht nötig. Die Freigaben gelten für diesen Mac.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $showsStoreImporter, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            let store = selectedStore
            Task { await model.acceptStoreSelection(result, for: store) }
        } onCancellation: {
            // Cancelling never replaces a previously saved grant.
        }
        .fileDialogMessage(selectedStore.instruction)
        .fileDialogConfirmationLabel("Lesen erlauben")
    }

    private func folderSelection(for id: String) -> (() -> Void)? {
        guard model.requiresStoreSelection else { return nil }
        let store: SandboxStoreAccess.Store
        switch id {
        case "mail_local_store": store = .mail
        case "voice_memos_store": store = .voiceMemos
        default: return nil
        }
        return { selectedStore = store; showsStoreImporter = true }
    }
}

private struct PermissionAccessRow: View {
    let item: DataItem
    let busy: Bool
    let request: () -> Void
    let openSettings: (String) -> Void
    let chooseFolder: (() -> Void)?
    private var state: String { item.metadata["state"] ?? "unknown" }
    private var granted: Bool { state == "authorized" }
    private var manual: Bool { item.id == "mail_local_store" || item.id == "voice_memos_store" }
    private var title: LocalizedStringResource {
        switch item.id {
        case "calendar": return "Kalender"
        case "contacts": return "Kontakte"
        case "reminders": return "Erinnerungen"
        case "mail_local_store": return "Mail"
        case "notes_automation": return "Notizen"
        case "photos": return "Fotos"
        case "voice_memos_store": return "Sprachmemos"
        case "speech_recognition": return "Spracherkennung"
        default: return LocalizedStringResource(stringLiteral: item.title)
        }
    }
    private var status: LocalizedStringResource {
        switch state {
        case "authorized": return item.metadata["restart_required"] == "true" ? "Freigegeben · App-Neustart nötig" : "Freigegeben"
        case "not_determined": return "Noch nicht angefragt"
        case "denied": return "Nicht freigegeben"
        case "restricted": return "Durch macOS eingeschränkt"
        case "limited": return "Teilweise freigegeben"
        case "write_only": return "Nur Schreibzugriff · Lesezugriff fehlt"
        case "error": return "Systemabfrage fehlgeschlagen"
        case "manual": return chooseFolder == nil ? "In Systemeinstellungen freigeben" : "Ordnerfreigabe prüfen"
        default: return "Status prüfen"
        }
    }
    private var pane: String {
        switch item.id {
        case "mail_local_store", "voice_memos_store": return "full_disk_access"
        case "notes_automation": return "automation"
        case "speech_recognition": return "speech"
        default: return item.id
        }
    }
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3).foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(status).font(.callout).foregroundStyle(.secondary)
                if state == "error", let detail = item.preview {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.id == "speech_recognition" {
                    Text("Nur für bestimmte neue Transkriptionen erforderlich.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let chooseFolder {
                Button("Ordner auswählen", action: chooseFolder).disabled(busy)
            } else if !granted && !manual && (state == "not_determined" || state == "error") {
                Button("Zugriff erlauben", action: request).disabled(busy)
            } else {
                Button("Einstellungen") { openSettings(pane) }.disabled(busy)
            }
        }.padding(.vertical, 4)
    }
}
