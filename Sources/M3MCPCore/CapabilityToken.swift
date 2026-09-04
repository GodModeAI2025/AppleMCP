import Foundation
import Security

/// The capability token the app hands out and the bridge presents on every tool call.
///
/// The token is one half of the access control on the socket; `PeerIdentity` is the other. On its
/// own a bearer token is a secret in a file: whoever can read `claude_desktop_config.json` or the
/// keychain item can replay it. It is still worth having, because it turns "connect to the socket"
/// from a capability every process of the user holds into one that has to be configured. What it is
/// not: a token stays usable when it is stolen. The pin only forces the thief through the bundled
/// bridge instead of a client of their own.
///
/// Where it lives: the login keychain, as a generic password. That is a deliberate choice over a
/// `0600` file next to the socket. A file in the socket directory would be readable by exactly the
/// set of processes that can already open the socket, so it would add nothing. A keychain item is
/// bound by its ACL to the binary that created it; another binary asking for it produces a user
/// prompt, and the prompt names the asker. That is a control the user can actually see.
///
/// The cost is honest and worth writing down: the app is signed ad hoc, so the ACL is tied to the
/// app's code directory hash. After an update the keychain re-prompts, exactly as the Full Disk
/// Access grant does.
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

    /// The token a client presents, or nil when none is configured. Never creates one: a client that
    /// invents a token would only ever be refused, and the error should say what to configure.
    public static func existing(service: String? = nil, account: String = defaultAccount) -> Resolution? {
        if let fromEnvironment = environmentToken() {
            return Resolution(token: fromEnvironment, origin: "\(environmentKey) environment variable")
        }

        let service = service ?? self.service
        guard let stored = ((try? read(service: service, account: account)) ?? nil) else {
            return nil
        }
        return Resolution(token: stored, origin: "keychain item \(service)")
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

    public static func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
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

    private static func environmentToken() -> String? {
        let raw = ProcessInfo.processInfo.environment[environmentKey] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
