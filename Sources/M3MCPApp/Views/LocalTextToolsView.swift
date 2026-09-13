import M3MCPCore
import SwiftUI

/// A native entry point to the same local tool exposed over MCP.
struct LocalTextToolsView: View {
    let process: (String, String) async -> ToolResponse
    @State private var input = ""
    @State private var style = "summary_and_actions"
    @State private var output = ""
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        Panel {
            Text("Text lokal bearbeiten").font(.headline)
            Text("Der Text bleibt auf diesem Mac. Das Apple-Modell benötigt Apple Intelligence. Prüfe das Ergebnis auf Fehler und Auslassungen.")
                .foregroundStyle(.secondary)
            Picker("Bearbeitung", selection: $style) {
                Text("Zusammenfassung und Aufgaben").tag("summary_and_actions")
                Text("Zusammenfassen").tag("summary")
                Text("Aufgaben extrahieren").tag("actions")
                Text("Kürzen").tag("concise")
                Text("Stichpunkte").tag("key_points")
            }.disabled(operation != nil)
            TextEditor(text: $input)
                .font(.body)
                .frame(minHeight: 140, maxHeight: 240)
                .accessibilityLabel("Zu bearbeitender Text")
                .disabled(operation != nil)
            HStack {
                Button("Lokal bearbeiten") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(operation != nil || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.count > 32_000)
                if operation != nil {
                    ProgressView().controlSize(.small)
                    Button("Abbrechen") { cancel() }
                }
                Spacer()
                Text("\(input.count) / 32.000 Zeichen").font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !output.isEmpty {
                Divider()
                Text("Ergebnis").font(.headline)
                Text(output).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .onDisappear { cancel() }
    }

    private func start() {
        error = nil
        output = ""
        let text = input
        let selectedStyle = style
        operation = Task { @MainActor in
            let response = await process(text, selectedStyle)
            guard !Task.isCancelled else { return }
            if response.ok, let item = response.items.first {
                output = item.preview ?? ""
            } else {
                error = response.message ?? String(localized: "Die lokale Bearbeitung ist nicht verfügbar.")
            }
            operation = nil
        }
    }

    private func cancel() {
        operation?.cancel()
        operation = nil
    }
}
