import M3MCPCore
import SwiftUI

struct DetailView: View {
    let service: ServiceHealth?
    let activity: [ActivityEntry]
    let permissionItems: [DataItem]
    let permissionMessage: String?
    let serverState: String
    let authenticationSummary: String
    let onPermissions: () -> Void
    let onPermissionRefresh: () -> Void
    let onOpenPermissionSettings: (String) -> Void
    let onStart: () -> Void
    let onRestart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let service {
                        ServiceSummaryView(service: service)
                    }

                    if service?.name == "Permissions" {
                        PermissionCenterView(
                            items: permissionItems,
                            message: permissionMessage,
                            onRequest: onPermissions,
                            onRefresh: onPermissionRefresh,
                            onOpenSettings: onOpenPermissionSettings
                        )
                    } else {
                        EndpointListView()
                    }

                    ActivityTableView(activity: activity)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Local MCP")
                    .font(.title3.weight(.semibold))
                Text("\(M3MCPEndpoint.displayPath)  \(serverState)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Whether the client binary is pinned or the endpoint is running on the token alone
                // belongs in front of the user, not only in /health.
                Text(authenticationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button(action: onPermissions) {
                Label("Permissions", systemImage: "key.fill")
            }
            .help("Request macOS permissions")

            Button(action: onStart) {
                Label("Start", systemImage: "play.fill")
            }
            .disabled(serverState == "running" || serverState == "starting")
            .help("Start local MCP endpoint")

            Button(action: onRestart) {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .help("Restart local HTTP endpoint")

            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(serverState == "stopped")
            .help("Stop local HTTP endpoint")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct ServiceSummaryView: View {
    let service: ServiceHealth

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            GridRow {
                Text("Source")
                    .foregroundStyle(.secondary)
                Text(service.name)
            }
            GridRow {
                Text("Endpoint")
                    .foregroundStyle(.secondary)
                Text(service.endpoint)
                    .textSelection(.enabled)
            }
            GridRow {
                Text("Mode")
                    .foregroundStyle(.secondary)
                Text(service.mode)
            }
            GridRow {
                Text("State")
                    .foregroundStyle(.secondary)
                Text(service.state)
            }
        }
        .font(.system(.body, design: .monospaced))
    }
}

private struct EndpointListView: View {
    private let tools: [(String, String)] = [
        ("source_status", "/tools/source_status"),
        ("permissions_status", "/tools/permissions_status"),
        ("permissions_request", "/tools/permissions_request"),
        ("permissions_open_settings", "/tools/permissions_open_settings"),
        ("calendar_search", "/tools/calendar_search"),
        ("contacts_search", "/tools/contacts_search"),
        ("mail_search", "/tools/mail_search"),
        ("mail_read", "/tools/mail_read"),
        ("reminders_search", "/tools/reminders_search"),
        ("notes_search", "/tools/notes_search"),
        ("notes_read", "/tools/notes_read"),
        ("photos_search", "/tools/photos_search"),
        ("photos_albums", "/tools/photos_albums"),
        ("voicememos_search", "/tools/voicememos_search"),
        ("voicememos_read", "/tools/voicememos_read"),
        ("voicememos_transcript", "/tools/voicememos_transcript"),
        ("voicememos_audio", "/tools/voicememos_audio"),
        ("voicememos_transcribe", "/tools/voicememos_transcribe"),
        ("ai_summarize", "/tools/ai_summarize"),
        ("ai_writing_tools", "/tools/ai_writing_tools"),
        ("ai_translate", "/tools/ai_translate"),
        ("ai_image_playground", "/tools/ai_image_playground")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP Tools")
                .font(.headline)

            Text(M3MCPEndpoint.healthCommand)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(tools, id: \.0) { name, endpoint in
                    GridRow {
                        Text(name)
                            .font(.system(.body, design: .monospaced))
                        Text(endpoint)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct PermissionCenterView: View {
    let items: [DataItem]
    let message: String?
    let onRequest: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Permissions")
                    .font(.headline)

                Spacer()

                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh permission state")

                Button(action: onRequest) {
                    Label("Request", systemImage: "key.fill")
                }
                .help("Request macOS permissions")
            }

            if let message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(items) { item in
                    PermissionRowView(item: item, onOpenSettings: onOpenSettings)
                }
            }
        }
    }
}

private struct PermissionRowView: View {
    let item: DataItem
    let onOpenSettings: (String) -> Void

    private var state: String {
        item.metadata["state"] ?? item.preview ?? "unknown"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                    Text(stateLabel)
                        .font(.caption)
                        .foregroundStyle(color)
                }

                Text(item.subtitle ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)

                if let preview = item.preview, preview != state {
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            if let pane {
                Button {
                    onOpenSettings(pane)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Open System Settings")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stateLabel: String {
        switch state {
        case "authorized":
            return "Authorized"
        case "not_determined":
            return "Not requested"
        case "denied":
            return "Denied"
        case "restricted":
            return "Restricted"
        case "limited":
            return "Limited"
        case "manual":
            return "Manual"
        case "unknown":
            return "Unknown"
        default:
            return state.capitalized
        }
    }

    private var icon: String {
        switch state {
        case "authorized":
            return "checkmark.circle.fill"
        case "manual", "unknown", "not_determined":
            return "questionmark.circle"
        default:
            return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case "authorized":
            return .green
        case "manual", "unknown", "not_determined":
            return .secondary
        default:
            return .orange
        }
    }

    private var pane: String? {
        switch item.id {
        case "calendar":
            return "calendar"
        case "contacts":
            return "contacts"
        case "reminders":
            return "reminders"
        case "mail_local_store":
            return "mail"
        case "photos":
            return "photos"
        case "notes_automation":
            return "automation"
        case "voice_memos_store":
            return "voice_memos"
        case "speech_recognition":
            return "speech"
        default:
            return nil
        }
    }
}

private struct ActivityTableView: View {
    let activity: [ActivityEntry]
    @State private var expandedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.headline)

            if activity.isEmpty {
                Text("No requests yet")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Time").frame(width: 70, alignment: .leading)
                        Text("Tool").frame(width: 160, alignment: .leading)
                        Text("Provider").frame(width: 120, alignment: .leading)
                        Text("Status").frame(width: 60, alignment: .leading)
                        Text("ms").frame(width: 50, alignment: .trailing)
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                    ForEach(activity) { entry in
                        ActivityRowView(entry: entry, isExpanded: expandedID == entry.id) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedID = expandedID == entry.id ? nil : entry.id
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ActivityRowView: View {
    let entry: ActivityEntry
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(entry.at, style: .time)
                    .frame(width: 70, alignment: .leading)
                Text(entry.toolName.isEmpty ? entry.endpoint : entry.toolName)
                    .frame(width: 160, alignment: .leading)
                    .lineLimit(1)
                Text(entry.provider)
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)
                Text(entry.status)
                    .frame(width: 60, alignment: .leading)
                    .foregroundStyle(entry.status == "ok" ? .green : .red)
                Text("\(entry.durationMilliseconds)")
                    .frame(width: 50, alignment: .trailing)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            if isExpanded {
                ActivityDetailView(entry: entry)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .background(isExpanded ? Color.accentColor.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ActivityDetailView: View {
    let entry: ActivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.status != "ok" {
                detailSection(title: "Error", content: entry.detail, style: .red)
            }

            if let input = entry.inputJSON, !input.isEmpty {
                detailSection(title: "Input", content: formatJSON(input))
            }

            if let output = entry.outputJSON, !output.isEmpty {
                detailSection(title: "Output", content: formatJSON(output))
            }

            if entry.status == "ok" && entry.inputJSON == nil && entry.outputJSON == nil {
                Text(entry.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailSection(title: String, content: String, style: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(style)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
        }
    }

    private func formatJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return text
    }
}
