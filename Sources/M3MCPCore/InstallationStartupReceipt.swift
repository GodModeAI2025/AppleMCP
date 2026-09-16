import Foundation

/// One installation attempt's diagnostic receipt. It grants no permission and contains no token.
/// The installer owns the private directory and validates nonce, executable and live launchd PID.
public struct InstallationStartupReceipt: Codable, Equatable {
    public let attempt: String
    public let pid: Int32
    public let executable: String
    public let state: String

    public static func report(_ state: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LOCALMCP_INSTALL_RECEIPT"],
              let attempt = environment["LOCALMCP_INSTALL_ATTEMPT"],
              UUID(uuidString: attempt) != nil,
              let executable = Bundle.main.executableURL?.path else { return }
        let receipt = Self(attempt: attempt, pid: ProcessInfo.processInfo.processIdentifier,
                           executable: executable, state: state)
        // The directory is deliberately not created here. After installation cleanup, ordinary
        // launches cannot recreate a stale installation receipt.
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
