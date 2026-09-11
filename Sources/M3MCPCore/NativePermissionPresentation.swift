import Foundation

/// UI evidence only, never an authorization decision for a provider or an MCP call.
/// EventKit on macOS can acknowledge a grant while its process-local preflight remains
/// not_determined until relaunch. Preserve the native callback and disclose that mismatch.
public struct NativePermissionPresentation {
    private var requests: [String: DataItem] = [:]
    public init() {}

    public mutating func received(_ item: DataItem) { requests[item.id] = item }

    public mutating func reconcile(_ snapshot: [DataItem]) -> [DataItem] {
        snapshot.map { fresh in
            guard let requested = requests[fresh.id] else { return fresh }
            let state = fresh.metadata["state"] ?? "unknown"
            // A definite fresh decision, including revocation, always wins.
            guard state == "not_determined" else {
                requests.removeValue(forKey: fresh.id)
                return fresh
            }
            var metadata = requested.metadata
            if metadata["state"] == "authorized" {
                metadata["restart_required"] = "true"
            }
            return DataItem(id: requested.id, title: requested.title, subtitle: requested.subtitle,
                kind: requested.kind, source: requested.source, preview: requested.preview,
                metadata: metadata)
        }
    }
}
