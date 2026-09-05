import M3MCPCore
import SwiftUI

struct DetailView: View {
    let service: ServiceHealth?
    let activity: [ActivityEntry]
    let permissionItems: [DataItem]
    let permissionMessage: String?
    let serverState: String
    let authenticationSummary: String
    let securityPolicy: M3MCPSecurityPolicy
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
                            permissionUIEnabled: securityPolicy.allowsPermissionUI,
                            onRequest: onPermissions,
                            onRefresh: onPermissionRefresh,
                            onOpenSettings: onOpenPermissionSettings
                        )
                    } else {
                        EndpointListView(securityPolicy: securityPolicy)
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
                // A degraded door has to be visible. Token-only, because no bridge was found next to
                // the app, reads the same as fully pinned unless it is written down somewhere.
                Text(authenticationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: onPermissions) {
                Label("Permissions", systemImage: "key.fill")
            }
            .disabled(!securityPolicy.allowsPermissionUI)
            .help(permissionUIHelp)

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

    private var permissionUIHelp: String {
        if securityPolicy.allowsPermissionUI {
            return "Request macOS permissions"
        }
        return "Permission UI is disabled. Relaunch M3MCP with \(M3MCPSecurityPolicy.permissionUIEnvironmentVariable)=1 to enable it."
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
    let securityPolicy: M3MCPSecurityPolicy

    private var tools: [M3MCPSecurityPolicy.ToolAvailability] {
        securityPolicy.toolAvailability
    }

    private var enabledCount: Int {
        tools.lazy.filter(\.isEnabled).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP Tools (\(enabledCount) enabled)")
                .font(.headline)

            Text(M3MCPEndpoint.healthCommand)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(tools) { tool in
                    GridRow {
                        Text(tool.name)
                            .font(.system(.body, design: .monospaced))
                        Text(tool.endpointPath)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        ToolAvailabilityLabel(tool: tool)
                    }
                }
            }
        }
    }
}

private struct ToolAvailabilityLabel: View {
    let tool: M3MCPSecurityPolicy.ToolAvailability

    var body: some View {
        if tool.isEnabled {
            Text(tool.requiresOptIn ? "Enabled (opt-in)" : "Enabled")
                .foregroundStyle(tool.requiresOptIn ? .orange : .green)
        } else if let variable = tool.requiredEnvironmentVariable {
            Text("Disabled - \(variable)=1")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Text("Disabled by policy")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionCenterView: View {
    let items: [DataItem]
    let message: String?
    let permissionUIEnabled: Bool
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
                .disabled(!permissionUIEnabled)
                .help(permissionUIHelp)
            }

            if !permissionUIEnabled {
                Label(permissionUIHelp, systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(items) { item in
                    PermissionRowView(
                        item: item,
                        permissionUIEnabled: permissionUIEnabled,
                        onOpenSettings: onOpenSettings
                    )
                }
            }
        }
    }

    private var permissionUIHelp: String {
        if permissionUIEnabled {
            return "Request macOS permissions"
        }
        return "Permission requests and Settings links are disabled by launch policy. Relaunch M3MCP with \(M3MCPSecurityPolicy.permissionUIEnvironmentVariable)=1 to enable them."
    }
}

private struct PermissionRowView: View {
    let item: DataItem
    let permissionUIEnabled: Bool
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
                .disabled(!permissionUIEnabled)
                .help(
                    permissionUIEnabled
                        ? "Open System Settings"
                        : "Settings links require \(M3MCPSecurityPolicy.permissionUIEnvironmentVariable)=1 at launch."
                )
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
