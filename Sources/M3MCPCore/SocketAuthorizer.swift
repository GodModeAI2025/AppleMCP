import Foundation

/// Decides whether an accepted connection may do what it is asking to do.
///
/// Two factors, and they fail differently on purpose:
///
///  * the **capability token** answers "is this client configured?". Missing or wrong is `401`.
///  * the **pinned code identity** answers "is this the client I was configured for?". A valid token
///    from the wrong binary is `403`, so a socket client somebody writes themselves does not get in
///    on a copied token alone.
///
/// What the pin is not: proof of who is calling. It identifies the binary on the other end, and the
/// bundled `M3MCPBridge` satisfies it whichever process starts it. A stolen token plus that bridge
/// is still a working client — see Known limits in docs/SECURITY_MODEL.md.
///
/// What is deliberately *not* checked: the peer's uid. The socket is `0600` inside a `0700`
/// directory, so the kernel refused every other uid before this code ran. Testing it here would
/// restate a condition already enforced and would read as security that is not there.
public struct SocketAuthorizer: Sendable {
    public enum Decision: Sendable, Equatable {
        case allow
        case deny(status: Int, reason: String)

        public var isAllowed: Bool {
            if case .allow = self { return true }
            return false
        }
    }

    /// The token every non-public request must present as `Authorization: Bearer <token>`.
    public let token: String

    /// Code directory hashes that may connect. Empty means pinning is off — see `pinningDescription`.
    public let trustedCodeDirectoryHashes: Set<String>

    /// Where the pin came from, in words. It goes into the refusal, because the likely cause of a
    /// `403` is a client pointed at a second copy of the bridge, and the message should name the copy
    /// that would work.
    public let trustDescription: String

    public init(
        token: String,
        trustedCodeDirectoryHashes: Set<String> = [],
        trustDescription: String = ""
    ) {
        self.token = token
        self.trustedCodeDirectoryHashes = Set(trustedCodeDirectoryHashes.map { $0.lowercased() })
        self.trustDescription = trustDescription
    }

    public var pinsPeerIdentity: Bool { !trustedCodeDirectoryHashes.isEmpty }

    /// One line for the app UI and for `/health`, so a degraded install is visible rather than quiet.
    public var pinningDescription: String {
        pinsPeerIdentity
            ? "token + pinned client (\(trustedCodeDirectoryHashes.count) code hash(es))"
            : "token only — no M3MCPBridge found next to the app, so the client binary is not pinned"
    }

    /// `/health` is the one path that answers without a token: it is the documented probe that
    /// `script/install_local.sh` waits on, and `AppModel` keeps the activity log out of it by
    /// answering it with `statusResponse(includeActivity: false)`.
    ///
    /// `/status` is not public. It carries up to 30 recent activity entries with tool inputs and
    /// bounded outputs, which is the most sensitive thing the endpoint can hand out.
    public static func isPublic(method: String, path: String) -> Bool {
        method == "GET" && path == "/health"
    }

    public func authorize(
        method: String,
        path: String,
        authorizationHeader: String?,
        peer: PeerIdentity
    ) -> Decision {
        if Self.isPublic(method: method, path: path) {
            return .allow
        }

        guard let presented = Self.bearerToken(in: authorizationHeader) else {
            return .deny(
                status: 401,
                reason: "This endpoint needs a capability token. Send 'Authorization: Bearer <token>'. "
                    + "M3MCPBridge reads the token from \(CapabilityToken.environmentKey) or from the "
                    + "login keychain; the M3MCP app shows it under Server."
            )
        }

        guard CapabilityToken.matches(presented, token) else {
            return .deny(status: 401, reason: "The capability token is not the one this M3MCP instance issued.")
        }

        guard pinsPeerIdentity else {
            return .allow
        }

        guard peer.signatureValid, let hash = peer.codeDirectoryHash else {
            return .deny(
                status: 403,
                reason: "The connecting process has no verifiable code signature, so it cannot be matched "
                    + "against the pinned client. Peer: \(peer.description)."
            )
        }

        guard trustedCodeDirectoryHashes.contains(hash.lowercased()) else {
            return .deny(
                status: 403,
                reason: "The token is valid, but it was presented by a process this instance is not "
                    + "configured for. Only the M3MCPBridge that ships with this app may connect"
                    + (trustDescription.isEmpty ? "" : " (\(trustDescription))")
                    + ". A second copy of the same bridge built elsewhere has a different code "
                    + "directory hash and is refused. Peer: \(peer.description)."
            )
        }

        return .allow
    }

    /// Case-insensitive on the scheme, because HTTP auth schemes are.
    public static func bearerToken(in header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// One authorization outcome, for the log and for the app's activity list.
public struct AccessAttempt: Sendable {
    public let method: String
    public let path: String
    public let peer: PeerIdentity
    public let allowed: Bool
    public let reason: String?

    public init(method: String, path: String, peer: PeerIdentity, allowed: Bool, reason: String? = nil) {
        self.method = method
        self.path = path
        self.peer = peer
        self.allowed = allowed
        self.reason = reason
    }
}
