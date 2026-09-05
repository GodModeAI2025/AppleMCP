import Foundation

/// Decides whether an accepted connection may do what it is asking to do.
///
/// The **capability token** answers "is this client configured?". Missing or wrong is `401`.
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

    public init(token: String) {
        self.token = token
    }

    /// One line for the app UI and for `/health`, so a degraded install is visible rather than quiet.
    public var pinningDescription: String {
        "token only"
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
        authorizationHeader: String?
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
    public let allowed: Bool
    public let reason: String?

    public init(method: String, path: String, allowed: Bool, reason: String? = nil) {
        self.method = method
        self.path = path
        self.allowed = allowed
        self.reason = reason
    }
}
