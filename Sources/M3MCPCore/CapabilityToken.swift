import Foundation
import Security

/// The capability token the app hands out and the bridge presents on every tool call.
///
/// Until this existed the only access control on the endpoint was the filesystem: a `0600` socket
/// in a `0700` directory. That keeps other users out and nothing else. Every unsandboxed process
/// running as the same user could connect and inherit the app's Full Disk Access. The token turns
/// "connect to the socket" from a capability every process of the user holds into one that has to
/// be configured.
///
/// What it is not: a token stays usable when it is copied. `SocketAuthorizer` pairs it with a pin on
/// the peer's code identity, which forces a thief through the bundled bridge rather than a client of
/// their own. Both halves are needed and neither is sufficient.
///
/// Where it lives: the login keychain, as a generic password. That is a deliberate choice over a
/// `0600` file next to the socket. Such a file would be readable by exactly the set of processes
/// that can already open the socket, so it would add nothing. A keychain item is bound by its ACL to
/// the binary that created it, and reaching it from anywhere else takes the user's say-so.
///
/// The cost changed for the better on this branch's base. `script/install_local.sh` and
/// `script/package_release.sh` both sign with a stable certificate and say why: an ad-hoc signature
/// puts the binary hash into the designated requirement, so every rebuild would silently invalidate
/// the Full Disk Access grant. The keychain ACL is bound the same way, so it survives a rebuild for
/// the same reason the TCC grant does. What does not change is that the bridge is a second binary:
/// it does not prompt, because the panel would appear in a session an MCP client has not got — see
/// `read(service:account:allowingInteraction:)`. So the fallback reaches an item already on this
/// bridge's ACL and no other, and a client that is not that has to be given `M3MCP_TOKEN`.
public enum CapabilityToken {
    /// Set this and it wins over the keychain, in the app and in the bridge alike.
    ///
    /// This is how an MCP client is configured (`"env": {"M3MCP_TOKEN": "…"}`) and how the tests run
    /// without touching a keychain that may not be unlocked.
    public static let environmentKey = "M3MCP_TOKEN"

    /// Lets a test — or a second installation — use its own keychain item instead of the real one.
    public static let serviceEnvironmentKey = "M3MCP_TOKEN_KEYCHAIN_SERVICE"

    public static let defaultService = "de.markzimmermann.m3mcp.capability-token"
    public static let defaultAccount = "default"

    /// A token plus where it came from, so the app can say so in its UI and the bridge in its errors.
    public struct Resolution: Sendable, Equatable {
        public let token: String
        public let origin: String

        public init(token: String, origin: String) {
            self.token = token
            self.origin = origin
        }
    }

    public enum Failure: LocalizedError {
        case keychain(OSStatus, String)
        case randomness(Int32)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status, let operation):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain \(operation) failed: \(text) (\(status))"
            case .randomness(let status):
                return "Could not read random bytes for a new token (SecRandomCopyBytes: \(status))"
            }
        }
    }

    public static var service: String {
        let override = ProcessInfo.processInfo.environment[serviceEnvironmentKey] ?? ""
        return override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultService : override
    }

    // MARK: - App side

    /// The token the server enforces. Generated and stored on first start.
    public static func loadOrCreate(service: String? = nil, account: String = defaultAccount) throws -> Resolution {
        if let fromEnvironment = environmentToken() {
            return Resolution(token: fromEnvironment, origin: "\(environmentKey) environment variable")
        }

        let service = service ?? self.service
        if let stored = try read(service: service, account: account) {
            return Resolution(token: stored, origin: "keychain item \(service)")
        }

        let token = try generate()
        try write(token: token, service: service, account: account)
        return Resolution(token: token, origin: "keychain item \(service), created on this start")
    }

    // MARK: - Client side

    /// What a client found, and when it found nothing, why.
    ///
    /// The reason matters because the two ways of finding nothing want different fixes: no item at
    /// all means the app has not run yet, while a refused item means this binary is not the one that
    /// created it and the token belongs in the client's configuration instead.
    public enum ClientToken: Sendable {
        case resolved(Resolution)
        case missing(reason: String)

        public var resolution: Resolution? {
            if case .resolved(let value) = self { return value }
            return nil
        }
    }

    /// The token a client presents. Never creates one: a client that invents a token would only ever
    /// be refused, and the error should say what to configure.
    ///
    /// The keychain read here refuses interaction on purpose. An MCP client starts the bridge with
    /// no window session of its own, and a keychain item created by another binary — which the app's
    /// item is, from the bridge's point of view — otherwise puts up an authorization panel: measured
    /// on a bridge started from a shell, `SecItemCopyMatching` had not returned after 25 seconds and
    /// nothing had been printed. To the MCP client that is a server that never answers.
    /// Refusing interaction turns that into an immediate error, and the message says to put the
    /// token in the client's configuration.
    public static func forClient(service: String? = nil, account: String = defaultAccount) -> ClientToken {
        if let fromEnvironment = environmentToken() {
            return .resolved(Resolution(token: fromEnvironment, origin: "\(environmentKey) environment variable"))
        }

        let service = service ?? self.service
        do {
            if let stored = try read(service: service, account: account, allowingInteraction: false) {
                return .resolved(Resolution(token: stored, origin: "keychain item \(service)"))
            }
            return .missing(
                reason: "there is no keychain item \(service). The M3MCP app creates it on its first start."
            )
        } catch CapabilityToken.Failure.keychain(let status, _)
            where status == errSecInteractionNotAllowed || status == errSecAuthFailed
                || status == errSecUserCanceled {
            // errSecAuthFailed is what the file-based keychain returns for "I would have asked, and
            // I was told not to". It reads like a wrong password and means a refused ACL.
            return .missing(
                reason: "the keychain item \(service) exists, but this binary may not read it without asking "
                    + "you first, and a bridge started by an MCP client has no way to ask."
            )
        } catch {
            return .missing(reason: error.localizedDescription)
        }
    }

    /// The token a client presents, or nil when none is configured.
    public static func existing(service: String? = nil, account: String = defaultAccount) -> Resolution? {
        forClient(service: service, account: account).resolution
    }

    // MARK: - Primitives

    /// 32 bytes from the system CSPRNG, base64url without padding, so it survives an environment
    /// variable, a JSON config file and an HTTP header untouched.
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw Failure.randomness(status)
        }

        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Comparison in time that does not depend on how many leading characters match.
    ///
    /// The length is allowed to leak — it is fixed by `generate()` — but the contents are not.
    public static func matches(_ presented: String, _ expected: String) -> Bool {
        let left = Array(presented.utf8)
        let right = Array(expected.utf8)
        guard !right.isEmpty, left.count == right.count else {
            return false
        }

        var difference: UInt8 = 0
        for index in 0..<right.count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    // MARK: - Keychain

    /// `allowingInteraction: false` is what keeps a read bounded.
    ///
    /// Without it `SecItemCopyMatching` waits for the authorization panel with no deadline of its
    /// own. That is right in an app with a window and is a hang anywhere else — measured on the
    /// bridge reading an item another binary created: no answer after 25 seconds and nothing on
    /// stdout, which an MCP client sees as a server that never replies.
    ///
    /// What does the bounding is `SecKeychainSetUserInteractionAllowed`, deprecated since 10.10 and
    /// still the only thing that works here. `kSecUseAuthenticationUI` was tried first and measured:
    /// with `…UIFail` and with `…UISkip` alike the call still had not returned after 20 seconds,
    /// because those govern the modern authentication path and not the ACL prompt of the file-based
    /// login keychain, which is the keychain an app without entitlements gets. With the legacy switch
    /// the same read comes back in 15 milliseconds as `errSecAuthFailed`.
    ///
    /// The switch is process-wide, so the previous value goes back before returning.
    public static func read(
        service: String,
        account: String,
        allowingInteraction: Bool = true
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = allowingInteraction
            ? SecItemCopyMatching(query as CFDictionary, &item)
            : copyWithoutInteraction(query, into: &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
                return nil
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status, "read")
        }
    }

    public static func write(token: String, service: String, account: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "M3MCP capability token"
        attributes[kSecAttrDescription as String] = "Authenticates an MCP client against the local M3MCP socket"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else {
                throw Failure.keychain(update, "update")
            }
        default:
            throw Failure.keychain(status, "write")
        }
    }

    public static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status, "delete")
        }
    }

    /// The one place the deprecated switch is touched, and deprecated itself so the warning lands
    /// here, once, next to the explanation instead of three times inside it.
    @available(
        macOS,
        deprecated: 10.10,
        message: "SecKeychainSetUserInteractionAllowed has no replacement that covers the file-based login keychain. Measured, not assumed: see read(service:account:allowingInteraction:)."
    )
    private static func copyWithoutInteraction(_ query: [String: Any], into item: inout CFTypeRef?) -> OSStatus {
        var wasAllowed: DarwinBoolean = true
        _ = SecKeychainGetUserInteractionAllowed(&wasAllowed)
        _ = SecKeychainSetUserInteractionAllowed(false)
        defer { _ = SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return SecItemCopyMatching(query as CFDictionary, &item)
    }

    private static func environmentToken() -> String? {
        let raw = ProcessInfo.processInfo.environment[environmentKey] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
