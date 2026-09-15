import Foundation

/// App-local, read-only grants. MCP clients cannot create or replace them.
/// Scopes stay active for this process; bookmarks are resolved without showing UI on relaunch.
final class SandboxStoreAccess: @unchecked Sendable {
    enum Store: String, CaseIterable, Sendable {
        case mail, voiceMemos
        var title: String { self == .mail ? String(localized: "Mail-Ordner") : String(localized: "Sprachmemo-Ordner") }
        var instruction: LocalizedStringResource {
            self == .mail
                ? "Wähle den Ordner Library/Mail in deinem Benutzerordner. Mit ⌘⇧G kannst du ~/Library/Mail eingeben."
                : "Wähle den Ordner Recordings, der CloudRecordings.db und die lokalen Sprachmemos enthält."
        }
    }

    struct AccessError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let shared = SandboxStoreAccess()
    private let lock = NSLock()
    private let preferences: UserDefaults
    private var active: [Store: URL] = [:]
    private var restored = false

    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    private func key(_ store: Store) -> String { "localmcp.sandbox.store.\(store.rawValue).bookmark" }

    func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard !restored else { return }
        restored = true
        for store in Store.allCases {
            guard let data = preferences.data(forKey: key(store)) else { continue }
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                    bookmarkDataIsStale: &stale)
                // A moved store must be reselected in the native read-only importer. Never
                // consume or renew a stale scope: on macOS 27 the renewed scope allowed writes
                // in the signed relocation probe despite the read-only bookmark creation flag.
                guard !stale else { continue }
                guard url.startAccessingSecurityScopedResource() else { continue }
                active[store] = url
            } catch {
                // Missing/stale/unresolvable grants fail closed; a fresh native selection is needed.
            }
        }
    }

    func url(for store: Store) throws -> URL {
        restore()
        lock.lock()
        defer { lock.unlock() }
        guard let url = active[store] else {
            throw AccessError(message: String(localized: "Bitte zuerst unter Freigaben den \(store.title) auswählen. Die Sandbox benötigt eine eigene Ordnerfreigabe; Festplattenvollzugriff allein reicht nicht."))
        }
        return url
    }

    /// Accepts only URLs returned by the native file importer in the app UI.
    func install(_ url: URL, for store: Store) throws {
        restore()
        guard url.startAccessingSecurityScopedResource() else {
            throw AccessError(message: String(localized: "macOS hat den Lesezugriff auf diesen Ordner nicht freigegeben."))
        }
        do {
            let data = try Self.bookmark(url)
            lock.lock()
            let previous = active.updateValue(url, forKey: store)
            preferences.set(data, forKey: key(store))
            lock.unlock()
            previous?.stopAccessingSecurityScopedResource()
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    deinit { for url in active.values { url.stopAccessingSecurityScopedResource() } }
}
