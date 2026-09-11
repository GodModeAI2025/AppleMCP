import M3MCPCore
import SwiftUI

enum AppDestination: Hashable {
    case overview, connection, permissions, activity, source(String)
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
}

struct PageHeading: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.weight(.bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusPill: View {
    let text: LocalizedStringKey
    let symbol: String
    var good = true
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(good ? Color.green : Color.orange)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((good ? Color.green : Color.orange).opacity(0.10), in: Capsule())
    }
}

struct FeatureIcon: View {
    let symbol: String
    var color: Color = .indigo
    var body: some View {
        Image(systemName: symbol).font(.title2.weight(.medium))
            .foregroundStyle(color).frame(width: 46, height: 46)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityHidden(true)
    }
}

struct SourcePresentation {
    let title: String
    let icon: String
    let description: String
    let permissionID: String?
    let prefix: String

    static func forName(_ name: String) -> SourcePresentation {
        switch name {
        case "Mail": return .init(title: "Mail", icon: "envelope", description: "Nachrichten und Postfächer aus Apple Mail durchsuchen.", permissionID: "mail_local_store", prefix: "mail_")
        case "Calendar": return .init(title: "Kalender", icon: "calendar", description: "Termine und Kalender auf deinem Mac finden.", permissionID: "calendar", prefix: "calendar_")
        case "Contacts / Address Book": return .init(title: "Kontakte", icon: "person.crop.circle", description: "Namen, Adressen und Kontaktdaten nachschlagen.", permissionID: "contacts", prefix: "contacts_")
        case "Reminders": return .init(title: "Erinnerungen", icon: "checklist", description: "Aufgaben und Erinnerungslisten lesen.", permissionID: "reminders", prefix: "reminders_")
        case "Notes": return .init(title: "Notizen", icon: "note.text", description: "Inhalte aus Apple Notizen suchen und lesen.", permissionID: "notes_automation", prefix: "notes_")
        case "Photos": return .init(title: "Fotos", icon: "photo", description: "Fotos und Alben anhand ihrer Metadaten finden.", permissionID: "photos", prefix: "photos_")
        case "Voice Memos": return .init(title: "Sprachmemos", icon: "waveform", description: "Aufnahmen finden und vorhandene Transkripte lesen.", permissionID: "voice_memos_store", prefix: "voicememos_")
        case "Foundation Models": return .init(title: "Sprachmodell", icon: "brain", description: "Texte mit dem verfügbaren lokalen Apple-Modell zusammenfassen.", permissionID: nil, prefix: "ai_summarize")
        default: return .init(title: "Apple Intelligence", icon: "sparkles", description: "Lokale Apple-Intelligence-Funktionen auf unterstützten Macs verwenden.", permissionID: nil, prefix: "ai_")
        }
    }
}
