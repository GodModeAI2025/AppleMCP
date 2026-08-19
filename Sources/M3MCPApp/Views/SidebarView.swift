import M3MCPCore
import SwiftUI

struct SidebarView: View {
    let services: [ServiceHealth]
    @Binding var selectedServiceName: String?

    var body: some View {
        List(selection: $selectedServiceName) {
            Section("Access") {
                ForEach(accessServices) { service in
                    serviceRow(service)
                        .tag(Optional(service.name))
                }
            }

            Section("Sources") {
                ForEach(sourceServices) { service in
                    serviceRow(service)
                        .tag(Optional(service.name))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("M3MCP")
    }

    private var accessServices: [ServiceHealth] {
        services.filter { $0.name == "Permissions" }
    }

    private var sourceServices: [ServiceHealth] {
        services.filter { $0.name != "Permissions" }
    }

    private func serviceRow(_ service: ServiceHealth) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: service.name))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .lineLimit(1)
                Text(service.mode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func icon(for name: String) -> String {
        switch name {
        case "Permissions": return "key"
        case "Mail": return "envelope"
        case "Calendar": return "calendar"
        case "Contacts / Address Book": return "person.crop.circle"
        case "Reminders": return "checklist"
        case "Notes": return "note.text"
        case "Photos": return "photo"
        case "Voice Memos": return "waveform"
        case "Apple Intelligence": return "sparkles"
        default: return "circle"
        }
    }
}
