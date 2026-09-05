import Foundation

/// Whether a write tool is being asked to preview a change or to perform it.
///
/// Before this existed, the only way to see what a mutation would do was to let it happen and read
/// the result back. The per-call approval sheet showed the arguments, not the effect: it could not
/// say which calendar a title resolves to, what an omitted `end` becomes, or which event an id
/// actually names. A caller who wanted that answer had to commit first.
///
/// `dry_run` is a separate question from consent, which is why it is a separate parameter rather
/// than a side effect of a missing confirmation. It resolves the same arguments, applies the same
/// validation, and reports the same target, and then stops.
///
/// The default is `commit`. An absent, false, or non-boolean value keeps the previous behaviour, so
/// no existing caller silently turns into a no-op. Only the literal boolean `true` selects a preview;
/// `M3MCPToolArgumentPolicy` has already rejected every other shape by the time this runs.
public enum M3MCPWriteIntent: String, Equatable, Sendable {
    case dryRun
    case commit

    public static let parameterName = "dry_run"

    public static func resolve(from input: [String: JSONValue]) -> M3MCPWriteIntent {
        if case .bool(true) = input[parameterName] ?? .null {
            return .dryRun
        }
        return .commit
    }

    public var writes: Bool { self == .commit }

    /// The `meta` entry every write tool sets, so a client can branch on the answer instead of
    /// parsing the prose in `message`.
    public var metaValue: String { self == .dryRun ? "true" : "false" }
}
