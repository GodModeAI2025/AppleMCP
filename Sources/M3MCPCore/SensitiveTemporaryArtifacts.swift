import Darwin
import Foundation

/// Cleanup policy for private Voice Memos snapshots and legacy speech-transcode scratch files.
///
/// Matching is deliberately strict: a cleanup candidate must have an exact M3MCP UUID name,
/// expected filesystem type, current process owner, and an age beyond the stale threshold.
public enum SensitiveTemporaryArtifacts {
    public static let defaultStaleAge: TimeInterval = 24 * 60 * 60
    /// A startup pass never inspects more top-level entries than this, even if a caller supplies a
    /// larger value. This keeps a hostile or accidentally huge shared temporary directory from
    /// turning best-effort maintenance into unbounded launch work.
    public static let maximumEntriesPerPass = 4_096
    /// Recursive removal can itself be non-trivial, so attempts are independently capped.
    public static let maximumRemovalsPerPass = 64

    public enum EntryType: Equatable, Sendable {
        case regularFile
        case directory
        case symbolicLink
        case other
    }

    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let type: EntryType
        public let ownerID: UInt32
        public let modificationDate: Date

        public init(name: String, type: EntryType, ownerID: UInt32, modificationDate: Date) {
            self.name = name
            self.type = type
            self.ownerID = ownerID
            self.modificationDate = modificationDate
        }
    }

    public struct CleanupResult: Equatable, Sendable {
        public let inspectedCount: Int
        public let removedCount: Int
        public let failedCount: Int
        public let entryLimitReached: Bool
        public let removalLimitReached: Bool
        public let cancelled: Bool

        public init(
            inspectedCount: Int = 0,
            removedCount: Int,
            failedCount: Int,
            entryLimitReached: Bool = false,
            removalLimitReached: Bool = false,
            cancelled: Bool = false
        ) {
            self.inspectedCount = inspectedCount
            self.removedCount = removedCount
            self.failedCount = failedCount
            self.entryLimitReached = entryLimitReached
            self.removalLimitReached = removalLimitReached
            self.cancelled = cancelled
        }
    }

    public static func shouldRemove(
        _ candidate: Candidate,
        ownerID: UInt32,
        now: Date,
        staleAge: TimeInterval = defaultStaleAge
    ) -> Bool {
        guard candidate.ownerID == ownerID else { return false }
        guard expectedType(forExactName: candidate.name) == candidate.type else { return false }
        guard staleAge.isFinite, staleAge >= 0 else { return false }

        let age = now.timeIntervalSince(candidate.modificationDate)
        return age.isFinite && age >= staleAge
    }

    /// Removes only stale artifacts immediately below `directory`; it never follows symlinks.
    /// Directory entries are consumed one at a time instead of first materializing the shared
    /// temporary directory. Both inspection and removal work have immutable hard ceilings.
    @discardableResult
    public static func removeStale(
        in directory: URL,
        fileManager: FileManager = .default,
        ownerID: UInt32 = getuid(),
        now: Date = Date(),
        staleAge: TimeInterval = defaultStaleAge,
        maximumEntries: Int = maximumEntriesPerPass,
        maximumRemovals: Int = maximumRemovalsPerPass,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> CleanupResult {
        let entryLimit = min(max(0, maximumEntries), maximumEntriesPerPass)
        let removalLimit = min(max(0, maximumRemovals), maximumRemovalsPerPass)

        let descriptor = directory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            return CleanupResult(removedCount: 0, failedCount: 0)
        }
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            return CleanupResult(removedCount: 0, failedCount: 0)
        }
        defer { closedir(stream) }

        var inspectedCount = 0
        var removedCount = 0
        var failedCount = 0
        var removalAttempts = 0
        var entryLimitReached = entryLimit == 0
        var removalLimitReached = removalLimit == 0
        var cancelled = false

        while inspectedCount < entryLimit, removalAttempts < removalLimit {
            if isCancelled() {
                cancelled = true
                break
            }

            guard let entry = readdir(stream) else { break }
            let name = entryName(entry)
            guard name != ".", name != ".." else { continue }
            inspectedCount += 1

            guard let candidate = candidate(named: name, relativeTo: dirfd(stream)),
                  shouldRemove(candidate, ownerID: ownerID, now: now, staleAge: staleAge)
            else {
                continue
            }

            if isCancelled() {
                cancelled = true
                break
            }

            removalAttempts += 1
            let child = directory.appendingPathComponent(
                name,
                isDirectory: candidate.type == .directory
            )
            do {
                try fileManager.removeItem(at: child)
                removedCount += 1
            } catch {
                failedCount += 1
            }
        }

        if !cancelled {
            entryLimitReached = entryLimitReached || inspectedCount >= entryLimit
            removalLimitReached = removalLimitReached || removalAttempts >= removalLimit
        }

        return CleanupResult(
            inspectedCount: inspectedCount,
            removedCount: removedCount,
            failedCount: failedCount,
            entryLimitReached: entryLimitReached,
            removalLimitReached: removalLimitReached,
            cancelled: cancelled
        )
    }

    private static func expectedType(forExactName name: String) -> EntryType? {
        let snapshotPrefix = "M3MCP-VoiceMemos-"
        if name.hasPrefix(snapshotPrefix) {
            let identifier = String(name.dropFirst(snapshotPrefix.count))
            return isCanonicalUUID(identifier) ? .directory : nil
        }

        let transcodePrefix = "m3mcp-transcode-"
        let transcodeSuffix = ".caf"
        if name.hasPrefix(transcodePrefix), name.hasSuffix(transcodeSuffix) {
            let start = name.index(name.startIndex, offsetBy: transcodePrefix.count)
            let end = name.index(name.endIndex, offsetBy: -transcodeSuffix.count)
            let identifier = String(name[start..<end])
            return isCanonicalUUID(identifier) ? .regularFile : nil
        }

        for (prefix, suffix) in [
            ("m3mcp-image-", ".png"),
            ("m3mcp-shortcut-input-", ".json")
        ] where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -suffix.count)
            let identifier = String(name[start..<end])
            return isCanonicalUUID(identifier) ? .regularFile : nil
        }

        return nil
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    private static func candidate(named name: String, relativeTo directoryDescriptor: Int32) -> Candidate? {
        var metadata = stat()
        let status = name.withCString { path in
            fstatat(directoryDescriptor, path, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { return nil }

        let type: EntryType
        switch metadata.st_mode & S_IFMT {
        case S_IFREG:
            type = .regularFile
        case S_IFDIR:
            type = .directory
        case S_IFLNK:
            type = .symbolicLink
        default:
            type = .other
        }

        let seconds = TimeInterval(metadata.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        return Candidate(
            name: name,
            type: type,
            ownerID: metadata.st_uid,
            modificationDate: Date(timeIntervalSince1970: seconds + nanoseconds)
        )
    }
}
