import Foundation

/// Works out which client binary this installation will accept.
///
/// There is no pairing dialog, so the answer has to come from something the installation already
/// knows for certain: the `M3MCPBridge` that sits next to the app's own executable. That holds in
/// both places the app ever runs from — `.build/<config>/` for a source build and
/// `M3MCP.app/Contents/MacOS/` for the installed and the packaged bundle — and it is exactly the
/// binary the README tells an MCP client to launch.
///
/// Reading it at every start is what keeps a hash pin from going stale: `script/install_local.sh`
/// and `script/package_release.sh` replace app and bridge together, so the next start pins the
/// bridge that was just installed.
///
/// When there is no sibling bridge the pin cannot be computed, and this says so rather than
/// pretending. The app then runs token-only, and `/health` and the app window both report it.
public enum TrustedClient {
    /// Overrides the sibling lookup with an explicit list of code directory hashes, comma-separated.
    ///
    /// For a client that lives somewhere else, and for tests. Setting it does not weaken anything an
    /// attacker could exploit: it is read from the *server's* environment, which only the person
    /// starting the server controls.
    public static let environmentKey = "M3MCP_TRUSTED_CLIENT_CDHASH"

    public static let bridgeExecutableName = "M3MCPBridge"

    public struct Resolution: Sendable {
        public let hashes: Set<String>
        public let note: String

        public init(hashes: Set<String>, note: String) {
            self.hashes = hashes
            self.note = note
        }
    }

    public static func resolve(appExecutableURL: URL?) -> Resolution {
        if let raw = ProcessInfo.processInfo.environment[environmentKey] {
            let hashes = Set(
                raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
            )
            if !hashes.isEmpty {
                return Resolution(hashes: hashes, note: "pinned from \(environmentKey)")
            }
        }

        guard let appExecutableURL else {
            return Resolution(
                hashes: [],
                note: "the app could not determine its own executable path, so the client binary is not pinned"
            )
        }

        let bridge = appExecutableURL
            .deletingLastPathComponent()
            .appendingPathComponent(bridgeExecutableName, isDirectory: false)

        guard FileManager.default.isExecutableFile(atPath: bridge.path) else {
            return Resolution(
                hashes: [],
                note: "no \(bridgeExecutableName) next to \(appExecutableURL.lastPathComponent), "
                    + "so the client binary is not pinned"
            )
        }

        guard let hash = PeerIdentity.codeDirectoryHash(ofFileAt: bridge) else {
            return Resolution(
                hashes: [],
                note: "\(bridge.path) has no readable code signature, so the client binary is not pinned"
            )
        }

        return Resolution(hashes: [hash], note: "pinned to \(bridge.path)")
    }
}
