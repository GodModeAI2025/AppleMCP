import SwiftUI

enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome, permissions, connection, finish
    var id: Int { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Willkommen"
        case .permissions: "Freigaben"
        case .connection: "Verbindung"
        case .finish: "Prüfen"
        }
    }
}

struct SetupAssistant: View {
    @ObservedObject var model: AppModel
    let completed: () -> Void
    @AppStorage("m3mcp.setup.v1.step") private var step: SetupStep = .welcome
    @State private var showsRiskNotice = false
    var body: some View {
        if !model.usageRiskAccepted || showsRiskNotice {
            UsageRiskDialog {
                model.acceptUsageRisk()
                showsRiskNotice = false
                model.startIfNeeded()
            } cancel: {
                model.showsSetup = false
            }
            .interactiveDismissDisabled()
        } else {
            assistant
        }
    }

    private var assistant: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LocalMCP einrichten").font(.title2.weight(.bold))
                    Text("Schritt \(step.rawValue + 1) von 4").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showsSetup = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Assistent später fortsetzen")
            }.padding(24)
            HStack(spacing: 12) {
                ForEach(SetupStep.allCases) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(item.rawValue <= step.rawValue ? Color.indigo : Color.secondary.opacity(0.18)).frame(height: 4)
                        Text(item.title).font(.caption.weight(.semibold))
                            .foregroundStyle(item == step ? Color.indigo : Color.secondary)
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .welcome: SetupWelcome()
                    case .permissions: PermissionsView(model: model, compact: true)
                    case .connection: ConnectionView(model: model, compact: true)
                    case .finish:
                        PageHeading(title: "Bereit für die erste Anfrage?", subtitle: "Prüfe die lokale Verbindung und lade danach LocalMCP in deinem Client neu.")
                        ConnectionCheckPanel(model: model)
                        Panel {
                            Text("Probiere es in deinem Client").font(.headline)
                            Text("„Zeige mir meine fünf neuesten Mails.“")
                            Text("„Liste meine letzten 45 Sprachmemos auf.“")
                            Text("Eine erfolgreiche Antwort hängt zusätzlich von den Freigaben für die jeweilige Datenquelle ab.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .windowBackgroundColor))
            Divider()
            HStack {
                Button("Zurück") { step = SetupStep(rawValue: step.rawValue - 1) ?? .welcome }
                    .disabled(step == .welcome)
                Button("Risikohinweis") { showsRiskNotice = true }
                Spacer()
                if step == .finish {
                    Button("Einrichtung abschließen") {
                        completed()
                        model.showsSetup = false
                        model.destination = .connection
                    }.buttonStyle(.borderedProminent).disabled(model.connectionVerified != true)
                } else {
                    Button(step == .permissions ? "Weiter zur Verbindung" : "Weiter") {
                        step = SetupStep(rawValue: step.rawValue + 1) ?? .finish
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(20)
        }.frame(width: 760, height: 720).tint(.indigo)
    }
}

private struct UsageRiskDialog: View {
    let accept: () -> Void
    let cancel: () -> Void
    @State private var understood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34)).foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nutzung auf eigene Gefahr").font(.title2.bold())
                    Text("Bitte lies diesen Hinweis, bevor du LocalMCP einrichtest.")
                        .foregroundStyle(.secondary)
                }
            }.padding(28)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("LocalMCP ermöglicht verbundenen KI- und MCP-Clients den Zugriff auf deine Daten. Je nach erteilten Freigaben, aktivierten Werkzeugen und ausgeführten Kurzbefehlen können Daten gelesen, weitergegeben, erstellt, verändert, überschrieben oder gelöscht werden.")
                    Text("Fehlerhafte Anweisungen, Softwarefehler oder missbräuchliche Zugriffe können zum Verlust sämtlicher Daten führen, auf die die aktivierten Funktionen zugreifen können. Änderungen und Löschungen können über iCloud auch andere Geräte betreffen. Eine Wiederherstellung ist nicht garantiert.")
                        .fontWeight(.semibold)
                    Text("Erstelle vor der Nutzung ein aktuelles Backup. Erteile nur notwendige Freigaben, verbinde nur vertrauenswürdige Clients und prüfe jede angeforderte Änderung sorgfältig. Inhalte können durch den verbundenen Client an externe Dienste übertragen werden.")
                    Text("Standardmäßig sind Kalenderänderungen und Kurzbefehle deaktiviert. Ihre Aktivierung und die erforderlichen Einzelfreigaben bleiben separate Entscheidungen. Diese Bestätigung erteilt keine zusätzlichen Zugriffsrechte.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(28)
            }
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                Toggle("Ich habe die Risiken einschließlich möglicher Datenänderungen und Datenverluste verstanden und möchte LocalMCP auf eigene Gefahr nutzen.", isOn: $understood)
                    .toggleStyle(.checkbox)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Abbrechen", action: cancel).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Bestätigen und fortfahren", action: accept)
                        .buttonStyle(.borderedProminent)
                        .disabled(!understood)
                }
            }.padding(28)
        }
        .frame(width: 720, height: 680)
        .tint(.indigo)
    }
}

private struct SetupWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            FeatureIcon(symbol: "wand.and.stars")
            PageHeading(title: "Dein Mac kann mehr.", subtitle: "LocalMCP verbindet Apple-Daten mit deinem MCP-Client. Dieser Assistent führt dich durch die Einrichtung.")
            Panel {
                SetupBenefit(icon: "hand.raised", title: "1. Daten auswählen", detail: "Du entscheidest, welche macOS-Freigaben du erteilst.")
                Divider()
                SetupBenefit(icon: "key.horizontal", title: "2. Token und Client verbinden", detail: "Ein Kopierknopf übernimmt den Token in die fertige Konfiguration.")
                Divider()
                SetupBenefit(icon: "checkmark.shield", title: "3. Verbindung testen", detail: "Die App prüft, ob Bridge und Anmeldung funktionieren.")
            }
            Text("Kein zusätzlicher Apple-Login. LocalMCP nutzt die auf diesem Mac verfügbaren Daten. Auf einem weiteren Mac richtest du Freigaben und Verbindung erneut ein.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
private struct SetupBenefit: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).foregroundStyle(.indigo).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}
