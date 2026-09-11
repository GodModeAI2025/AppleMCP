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
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("M3MCP einrichten").font(.title2.weight(.bold))
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
                        PageHeading(title: "Bereit für die erste Anfrage?", subtitle: "Prüfe die lokale Verbindung und lade danach M3MCP in deinem Client neu.")
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
private struct SetupWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            FeatureIcon(symbol: "wand.and.stars")
            PageHeading(title: "Dein Mac kann mehr.", subtitle: "M3MCP verbindet Apple-Daten mit deinem MCP-Client. Dieser Assistent führt dich durch die Einrichtung.")
            Panel {
                SetupBenefit(icon: "hand.raised", title: "1. Daten auswählen", detail: "Du entscheidest, welche macOS-Freigaben du erteilst.")
                Divider()
                SetupBenefit(icon: "key.horizontal", title: "2. Token und Client verbinden", detail: "Ein Kopierknopf übernimmt den Token in die fertige Konfiguration.")
                Divider()
                SetupBenefit(icon: "checkmark.shield", title: "3. Verbindung testen", detail: "Die App prüft, ob Bridge und Anmeldung funktionieren.")
            }
            Text("Kein zusätzlicher Apple-Login. M3MCP nutzt die auf diesem Mac verfügbaren Daten. Auf einem weiteren Mac richtest du Freigaben und Verbindung erneut ein.")
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
