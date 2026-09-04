import Darwin
import Foundation
import Security

/// Who is on the other end of an accepted Unix-socket connection.
///
/// Why this exists at all: until now the only access control on the endpoint was the filesystem —
/// a `0600` socket in a `0700` directory. That keeps other *users* out, and nothing else. Every
/// unsandboxed process running as the same user could connect and inherit the app's Full Disk
/// Access. Checking `getpeereid` would not have improved on that by one bit: it tests the condition
/// the kernel already enforced when it let the `connect` through.
///
/// What does carry weight on macOS is the peer's *code* identity. `LOCAL_PEERTOKEN` hands the
/// listener the audit token of the connecting process, and the Security framework turns that token
/// into a `SecCode` whose signature can be checked and whose code directory hash can be read. The
/// hash is over the binary's own pages: another process cannot present it without being that
/// binary. That works with an ad-hoc signature, which matters here, because this project has no
/// Developer ID and cannot pin a team identifier.
///
/// The audit token is used in preference to the pid because a pid can be recycled between the
/// `accept` and the lookup, and the token identifies one specific process instance.
public struct PeerIdentity: Sendable, Equatable {
    public let processIdentifier: pid_t
    public let userIdentifier: uid_t

    /// `kSecCodeInfoIdentifier` — the signing identifier, e.g. `M3MCPBridge`. Weak on its own:
    /// anyone can ad-hoc sign a binary under any identifier. Useful for logs and messages.
    public let signingIdentifier: String?

    /// `kSecCodeInfoUnique`, lowercase hex — the code directory hash. This is the part worth pinning.
    public let codeDirectoryHash: String?

    public let executablePath: String?

    /// `SecCodeCheckValidity` succeeded: the running code still matches what was signed.
    public let signatureValid: Bool

    /// Why the identity is incomplete, when it is. Nil when everything resolved.
    public let note: String?

    public init(
        processIdentifier: pid_t,
        userIdentifier: uid_t,
        signingIdentifier: String? = nil,
        codeDirectoryHash: String? = nil,
        executablePath: String? = nil,
        signatureValid: Bool = false,
        note: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.userIdentifier = userIdentifier
        self.signingIdentifier = signingIdentifier
        self.codeDirectoryHash = codeDirectoryHash
        self.executablePath = executablePath
        self.signatureValid = signatureValid
        self.note = note
    }

    /// One line for a log or an activity entry. Never carries the token.
    public var description: String {
        var parts = ["pid \(processIdentifier)", "uid \(userIdentifier)"]
        if let signingIdentifier { parts.append("id \(signingIdentifier)") }
        if let codeDirectoryHash { parts.append("cdhash \(codeDirectoryHash.prefix(12))…") }
        if let executablePath { parts.append(executablePath) }
        if !signatureValid { parts.append("unverified signature") }
        if let note { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Resolution

    /// Reads the peer of an accepted socket. Never throws: an identity that could not be resolved is
    /// still reported, with `note` saying what failed, so the caller can decide whether to refuse.
    public static func resolve(descriptor: Int32) -> PeerIdentity {
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(descriptor, &uid, &gid) != 0 {
            uid = uid_t.max
        }

        var pid: pid_t = -1
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        _ = withUnsafeMutablePointer(to: &pid) { pointer in
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, pointer, &pidSize)
        }

        guard let auditToken = auditToken(of: descriptor) else {
            return PeerIdentity(
                processIdentifier: pid,
                userIdentifier: uid,
                note: "LOCAL_PEERTOKEN is unavailable on this socket, so the peer's code identity could not be read"
            )
        }

        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &code)
        guard guestStatus == errSecSuccess, let code else {
            return PeerIdentity(
                processIdentifier: pid,
                userIdentifier: uid,
                note: "the peer has no code identity (SecCodeCopyGuestWithAttributes: \(guestStatus))"
            )
        }

        // Dynamic validity, not just "it is signed": this fails when the pages on disk were changed
        // after signing, which is the case a hash pin alone would not catch.
        let validity = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)

        var staticCode: SecStaticCode?
        SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode)

        var identifier: String?
        var hash: String?
        var path: String?

        if let staticCode {
            var information: CFDictionary?
            if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 0), &information) == errSecSuccess,
               let dictionary = information as? [String: Any] {
                identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
                hash = (dictionary[kSecCodeInfoUnique as String] as? Data).map(hexadecimal)
            }

            var url: CFURL?
            if SecCodeCopyPath(staticCode, SecCSFlags(rawValue: 0), &url) == errSecSuccess {
                path = (url as URL?)?.path
            }
        }

        return PeerIdentity(
            processIdentifier: pid,
            userIdentifier: uid,
            signingIdentifier: identifier,
            codeDirectoryHash: hash,
            executablePath: path,
            signatureValid: validity == errSecSuccess,
            note: validity == errSecSuccess ? nil : "SecCodeCheckValidity failed (\(validity))"
        )
    }

    /// The code directory hash of a binary on disk, in the same form `codeDirectoryHash` reports.
    ///
    /// Used to work out what to pin: the app hashes the `M3MCPBridge` next to its own executable and
    /// accepts connections from that binary and no other.
    public static func codeDirectoryHash(ofFileAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 0), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let data = dictionary[kSecCodeInfoUnique as String] as? Data
        else {
            return nil
        }

        return hexadecimal(data)
    }

    /// The hash of the calling process, so a test — or a diagnostic — can pin itself.
    public static func codeDirectoryHashOfCurrentProcess() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 0), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let data = dictionary[kSecCodeInfoUnique as String] as? Data
        else {
            return nil
        }

        return hexadecimal(data)
    }

    // MARK: - Internals

    private static func auditToken(of descriptor: Int32) -> Data? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, pointer, &size)
        }
        guard result == 0, size == socklen_t(MemoryLayout<audit_token_t>.size) else {
            return nil
        }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    private static func hexadecimal(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
