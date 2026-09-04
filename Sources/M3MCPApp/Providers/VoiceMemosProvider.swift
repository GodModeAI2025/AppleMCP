import Darwin
import Foundation
import M3MCPCore
import SQLite3

/// Bounds values SQLite may materialize from the Full-Disk-Access Voice Memos snapshot before
/// Swift creates a `String`. The store is normally tiny, but it remains an untrusted parser input:
/// a corrupt TEXT cell must not turn a 1 GiB snapshot allowance into a 1 GiB process allocation.
enum VoiceMemoSQLiteValuePolicy {
    static let maximumSQLiteValueBytes = 256 * 1_024
    static let maximumPathBytes = 4_096
    static let maximumLabelBytes = 4_096
    static let maximumTitleBytes = 4_096
    static let maximumDigestTextBytes = 128
    static let maximumSchemaIdentifierBytes = 128

    enum Violation: Error, Equatable, LocalizedError {
        case oversized(field: String, bytes: Int, maximum: Int)
        case invalidText(field: String)
        case embeddedNUL(field: String)

        var errorDescription: String? {
            switch self {
            case .oversized(let field, let bytes, let maximum):
                return "Voice Memos store field \(field) is \(bytes) bytes; maximum is \(maximum)."
            case .invalidText(let field):
                return "Voice Memos store field \(field) is not valid UTF-8 text."
            case .embeddedNUL(let field):
                return "Voice Memos store field \(field) contains an embedded NUL byte."
            }
        }
    }

    static func applyConnectionLimit(to database: OpaquePointer) {
        sqlite3_limit(
            database,
            SQLITE_LIMIT_LENGTH,
            Int32(maximumSQLiteValueBytes)
        )
    }

    static func text(
        _ statement: OpaquePointer,
        column: Int32,
        field: String,
        maximumBytes: Int
    ) throws -> String? {
        let type = sqlite3_column_type(statement, column)
        guard type != SQLITE_NULL else { return nil }
        guard type == SQLITE_TEXT else {
            throw Violation.invalidText(field: field)
        }

        // For an existing TEXT value, `sqlite3_column_bytes` reports its exact UTF-8 storage size
        // without requiring an unbounded Swift C-string scan. The connection-level length limit
        // caps SQLite's own materialization before this accessor is reached.
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount >= 0, byteCount <= maximumBytes else {
            throw Violation.oversized(
                field: field,
                bytes: max(0, byteCount),
                maximum: maximumBytes
            )
        }
        guard let bytes = sqlite3_column_text(statement, column) else {
            throw Violation.invalidText(field: field)
        }
        let buffer = UnsafeBufferPointer(start: bytes, count: byteCount)
        guard !buffer.contains(0) else {
            throw Violation.embeddedNUL(field: field)
        }
        guard let value = String(bytes: buffer, encoding: .utf8) else {
            throw Violation.invalidText(field: field)
        }
        return value
    }
}

/// Descriptor-anchored copy of the Voice Memos SQLite/WAL/SHM set.
///
/// The app has Full Disk Access, so a pathname-only temporary copy would expose path-substitution
/// and cleanup primitives to another process watching the temporary directory. Creation, copying,
/// and cleanup stay relative to open directory descriptors; source opens reject every symlink
/// component. Observable in-place changes are checked separately, but these checks are not
/// authentication against a malicious process inside the local operating-system account boundary.
final class SecureVoiceMemoStoreSnapshot: @unchecked Sendable {
    enum SnapshotError: Error, LocalizedError {
        case invalidParent(Int32)
        case createDirectory(Int32)
        case openDirectory(Int32)
        case unsafeSource(String, Int32)
        case createDestination(String, Int32)
        case copyFailed(String, Int32)
        case sizeLimit(String)
        case validationFailed
        case cleanupFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidParent(let code):
                return "temporary parent is not a safe owned directory (errno \(code))"
            case .createDirectory(let code):
                return "could not create the private snapshot directory (errno \(code))"
            case .openDirectory(let code):
                return "could not anchor the private snapshot directory (errno \(code))"
            case .unsafeSource(let name, let code):
                return "\(name) is missing, linked, or not an owned regular file (errno \(code))"
            case .createDestination(let name, let code):
                return "could not create private snapshot component \(name) (errno \(code))"
            case .copyFailed(let name, let code):
                return "could not copy snapshot component \(name) (errno \(code))"
            case .sizeLimit(let name):
                return "snapshot component \(name) exceeds the 1 GiB safety limit"
            case .validationFailed:
                return "the private snapshot path, inode, or observable content metadata changed"
            case .cleanupFailed(let code):
                return "could not remove the private snapshot directory (errno \(code))"
            }
        }
    }

    private struct Identity: Sendable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
    }

    /// Observable content metadata for a copied component. Device/inode alone detect replacement,
    /// but an owner can rewrite the same inode in place. Size plus modification/change timestamps
    /// make that ordinary same-inode mutation fail both the pre-open and post-read validations.
    private struct ComponentIdentity: Sendable {
        let file: Identity
        let size: off_t
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    static let maximumComponentBytes: UInt64 = 1_024 * 1_024 * 1_024
    private static let databaseSuffixes = ["", "-wal", "-shm"]
    private static let cleanupSuffixes = ["", "-wal", "-shm", "-journal"]

    let directory: URL
    let database: URL

    private let parentDescriptor: Int32
    private let parentPath: String
    private let directoryDescriptor: Int32
    private let directoryName: String
    private let databaseName: String
    private let parentIdentity: Identity
    private let directoryIdentity: Identity
    private var componentIdentities: [String: ComponentIdentity]
    private let validationLock = NSLock()
    private let cleanupLock = NSLock()
    private var cleaned = false

    static func create(
        sourceDatabase: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> SecureVoiceMemoStoreSnapshot {
        // Foundation's `resolvingSymlinksInPath()` can normalize an existing `/private/tmp` path
        // back to the `/tmp` symlink spelling. POSIX realpath gives the actual canonical object,
        // after which O_NOFOLLOW_ANY can safely reject any later component replacement.
        var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = temporaryDirectory.path.withCString { path in
            canonicalBuffer.withUnsafeMutableBufferPointer { buffer in
                Darwin.realpath(path, buffer.baseAddress) != nil
            }
        }
        guard resolved else {
            throw SnapshotError.invalidParent(errno)
        }
        let canonicalTemporaryDirectory = URL(
            fileURLWithPath: String(cString: canonicalBuffer),
            isDirectory: true
        )
        let parent = Darwin.open(
            canonicalTemporaryDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard parent >= 0 else {
            throw SnapshotError.invalidParent(errno)
        }

        var parentMetadata = stat()
        guard fstat(parent, &parentMetadata) == 0,
              parentMetadata.st_uid == getuid(),
              parentMetadata.st_mode & S_IFMT == S_IFDIR,
              parentMetadata.st_mode & 0o077 == 0 else {
            let code = errno
            Darwin.close(parent)
            throw SnapshotError.invalidParent(code)
        }

        let directoryName = "M3MCP-VoiceMemos-\(UUID().uuidString)"
        let created = directoryName.withCString {
            mkdirat(parent, $0, S_IRWXU)
        }
        guard created == 0 else {
            let code = errno
            Darwin.close(parent)
            throw SnapshotError.createDirectory(code)
        }

        let directoryDescriptor = directoryName.withCString {
            openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard directoryDescriptor >= 0 else {
            let code = errno
            _ = directoryName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            Darwin.close(parent)
            throw SnapshotError.openDirectory(code)
        }
        guard fchmod(directoryDescriptor, S_IRWXU) == 0 else {
            let code = errno
            Darwin.close(directoryDescriptor)
            _ = directoryName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            Darwin.close(parent)
            throw SnapshotError.openDirectory(code)
        }

        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0,
              directoryMetadata.st_uid == getuid(),
              directoryMetadata.st_mode & S_IFMT == S_IFDIR else {
            let code = errno
            Darwin.close(directoryDescriptor)
            _ = directoryName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            Darwin.close(parent)
            throw SnapshotError.openDirectory(code)
        }

        let databaseName = sourceDatabase.lastPathComponent
        guard !databaseName.isEmpty,
              databaseName != ".",
              databaseName != "..",
              !databaseName.contains("/") else {
            Darwin.close(directoryDescriptor)
            _ = directoryName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            Darwin.close(parent)
            throw SnapshotError.unsafeSource(databaseName, EINVAL)
        }

        var componentIdentities: [String: ComponentIdentity] = [:]
        do {
            for suffix in databaseSuffixes {
                let source = URL(fileURLWithPath: sourceDatabase.path + suffix)
                let destinationName = databaseName + suffix
                if let identity = try copyComponent(
                    source: source,
                    destinationName: destinationName,
                    directoryDescriptor: directoryDescriptor,
                    required: suffix.isEmpty
                ) {
                    componentIdentities[destinationName] = identity
                }
            }
        } catch {
            for suffix in cleanupSuffixes {
                let name = databaseName + suffix
                _ = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
            }
            Darwin.close(directoryDescriptor)
            _ = directoryName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            Darwin.close(parent)
            throw error
        }

        let directory = canonicalTemporaryDirectory.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        return SecureVoiceMemoStoreSnapshot(
            directory: directory,
            database: directory.appendingPathComponent(databaseName),
            parentDescriptor: parent,
            parentPath: canonicalTemporaryDirectory.path,
            directoryDescriptor: directoryDescriptor,
            directoryName: directoryName,
            databaseName: databaseName,
            parentIdentity: identity(parentMetadata),
            directoryIdentity: identity(directoryMetadata),
            componentIdentities: componentIdentities
        )
    }

    private init(
        directory: URL,
        database: URL,
        parentDescriptor: Int32,
        parentPath: String,
        directoryDescriptor: Int32,
        directoryName: String,
        databaseName: String,
        parentIdentity: Identity,
        directoryIdentity: Identity,
        componentIdentities: [String: ComponentIdentity]
    ) {
        self.directory = directory
        self.database = database
        self.parentDescriptor = parentDescriptor
        self.parentPath = parentPath
        self.directoryDescriptor = directoryDescriptor
        self.directoryName = directoryName
        self.databaseName = databaseName
        self.parentIdentity = parentIdentity
        self.directoryIdentity = directoryIdentity
        self.componentIdentities = componentIdentities
    }

    deinit {
        try? cleanup()
    }

    func validateBeforeOpen() -> Bool {
        validationLock.lock()
        defer { validationLock.unlock() }
        return validateDirectoryAnchor() && validateComponentSet()
    }

    /// SQLite may map the copied WAL/SHM while opening read-only. Directory anchors, component
    /// inodes, sizes, and modification/change timestamps must still match the copies made above.
    /// SQLite legitimately updates its existing shared-memory sidecar while establishing WAL read
    /// locks, so only that same safe `-shm` inode may adopt a new metadata baseline at this boundary.
    func validateAfterOpen() -> Bool {
        validationLock.lock()
        defer { validationLock.unlock() }
        return validateDirectoryAnchor() && validateComponentSet(acceptSQLiteSHMUpdate: true)
    }

    /// Once SQLite has established the transaction, no copied component may change while provider
    /// queries consume it.
    func validateAfterRead() -> Bool {
        validationLock.lock()
        defer { validationLock.unlock() }
        return validateDirectoryAnchor() && validateComponentSet()
    }

    func cleanup() throws {
        cleanupLock.lock()
        guard !cleaned else {
            cleanupLock.unlock()
            return
        }
        cleaned = true
        cleanupLock.unlock()

        for suffix in Self.cleanupSuffixes {
            let name = databaseName + suffix
            _ = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
        }
        Darwin.close(directoryDescriptor)

        var current = stat()
        let inspected = directoryName.withCString {
            fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        var cleanupError: Int32?
        if inspected == 0, Self.matches(current, directoryIdentity) {
            let removed = directoryName.withCString {
                unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            }
            if removed != 0 { cleanupError = errno }
        }
        Darwin.close(parentDescriptor)
        if let cleanupError {
            throw SnapshotError.cleanupFailed(cleanupError)
        }
    }

    private func validateDirectoryAnchor() -> Bool {
        var anchoredParent = stat()
        guard fstat(parentDescriptor, &anchoredParent) == 0,
              Self.matches(anchoredParent, parentIdentity),
              Self.isPrivateDirectory(anchoredParent) else {
            return false
        }

        // The SQLite API accepts only a path. Re-open that path with no-follow-all and compare it
        // with the retained parent descriptor immediately before and after SQLite opens the DB.
        let namedParentDescriptor = Darwin.open(
            parentPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard namedParentDescriptor >= 0 else { return false }
        defer { Darwin.close(namedParentDescriptor) }
        var namedParent = stat()
        guard fstat(namedParentDescriptor, &namedParent) == 0,
              Self.matches(namedParent, parentIdentity),
              Self.isPrivateDirectory(namedParent) else {
            return false
        }

        var anchored = stat()
        var named = stat()
        guard fstat(directoryDescriptor, &anchored) == 0,
              Self.matches(anchored, directoryIdentity),
              directoryName.withCString({
                fstatat(parentDescriptor, $0, &named, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              Self.matches(named, directoryIdentity),
              named.st_uid == getuid(),
              named.st_mode & S_IFMT == S_IFDIR,
              named.st_mode & 0o077 == 0 else {
            return false
        }
        return true
    }

    private func validateComponentSet(acceptSQLiteSHMUpdate: Bool = false) -> Bool {
        guard componentIdentities[databaseName] != nil else { return false }

        for suffix in Self.databaseSuffixes {
            let name = databaseName + suffix
            var metadata = stat()
            let status = name.withCString {
                fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            if let expected = componentIdentities[name] {
                guard status == 0,
                      Self.isSafeRegular(metadata),
                      Self.matches(metadata, expected.file) else {
                    return false
                }
                if acceptSQLiteSHMUpdate, suffix == "-shm" {
                    componentIdentities[name] = Self.componentIdentity(metadata)
                } else if !Self.matches(metadata, expected) {
                    return false
                }
            } else {
                guard status != 0, errno == ENOENT else { return false }
            }
        }

        // A copied WAL database never has a rollback journal. Rejecting an unexpected sidecar
        // narrows the path-substitution surface before SQLite parses the copy.
        let journalName = databaseName + "-journal"
        var journalMetadata = stat()
        let journalStatus = journalName.withCString {
            fstatat(directoryDescriptor, $0, &journalMetadata, AT_SYMLINK_NOFOLLOW)
        }
        return journalStatus != 0 && errno == ENOENT
    }

    private static func copyComponent(
        source: URL,
        destinationName: String,
        directoryDescriptor: Int32,
        required: Bool
    ) throws -> ComponentIdentity? {
        let sourceDescriptor = Darwin.open(
            source.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        if sourceDescriptor < 0, !required, errno == ENOENT {
            return nil
        }
        guard sourceDescriptor >= 0 else {
            throw SnapshotError.unsafeSource(source.lastPathComponent, errno)
        }
        defer { Darwin.close(sourceDescriptor) }

        var sourceMetadata = stat()
        guard fstat(sourceDescriptor, &sourceMetadata) == 0,
              isSafeRegular(sourceMetadata) else {
            throw SnapshotError.unsafeSource(source.lastPathComponent, errno)
        }
        guard sourceMetadata.st_size >= 0,
              UInt64(sourceMetadata.st_size) <= maximumComponentBytes else {
            throw SnapshotError.sizeLimit(source.lastPathComponent)
        }

        let destinationDescriptor = destinationName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                S_IRUSR | S_IWUSR
            )
        }
        guard destinationDescriptor >= 0 else {
            throw SnapshotError.createDestination(destinationName, errno)
        }
        var keepDestination = false
        defer {
            Darwin.close(destinationDescriptor)
            if !keepDestination {
                _ = destinationName.withCString {
                    unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var total: UInt64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw SnapshotError.copyFailed(destinationName, errno)
            }
            if count == 0 { break }
            let addition = total.addingReportingOverflow(UInt64(count))
            guard !addition.overflow, addition.partialValue <= maximumComponentBytes else {
                throw SnapshotError.sizeLimit(destinationName)
            }
            total = addition.partialValue

            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.write(
                        destinationDescriptor,
                        base.advanced(by: offset),
                        count - offset
                    )
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw SnapshotError.copyFailed(destinationName, errno)
                }
                offset += written
            }
        }

        guard fchmod(destinationDescriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(destinationDescriptor) == 0 else {
            throw SnapshotError.copyFailed(destinationName, errno)
        }
        var destinationMetadata = stat()
        guard fstat(destinationDescriptor, &destinationMetadata) == 0,
              isSafeRegular(destinationMetadata),
              UInt64(destinationMetadata.st_size) == total else {
            throw SnapshotError.copyFailed(destinationName, errno)
        }
        keepDestination = true
        return componentIdentity(destinationMetadata)
    }

    private static func isSafeRegular(_ metadata: stat) -> Bool {
        metadata.st_uid == getuid()
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_nlink == 1
    }

    private static func isPrivateDirectory(_ metadata: stat) -> Bool {
        metadata.st_uid == getuid()
            && metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_mode & 0o077 == 0
    }

    private static func identity(_ metadata: stat) -> Identity {
        Identity(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            owner: metadata.st_uid
        )
    }

    private static func componentIdentity(_ metadata: stat) -> ComponentIdentity {
        ComponentIdentity(
            file: identity(metadata),
            size: metadata.st_size,
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private static func matches(_ metadata: stat, _ identity: Identity) -> Bool {
        metadata.st_dev == identity.device
            && metadata.st_ino == identity.inode
            && metadata.st_uid == identity.owner
    }

    private static func matches(_ metadata: stat, _ identity: ComponentIdentity) -> Bool {
        matches(metadata, identity.file)
            && metadata.st_size == identity.size
            && Int64(metadata.st_mtimespec.tv_sec) == identity.modificationSeconds
            && Int64(metadata.st_mtimespec.tv_nsec) == identity.modificationNanoseconds
            && Int64(metadata.st_ctimespec.tv_sec) == identity.changeSeconds
            && Int64(metadata.st_ctimespec.tv_nsec) == identity.changeNanoseconds
    }
}

/// A recording pathname paired with the directory and file identities observed during store-row
/// resolution. Every later read opens relative to a no-follow directory descriptor and validates
/// the identity on the opened file descriptor before any Full Disk Access data is consumed.
struct SecureVoiceMemoRecording: Sendable {
    enum RecordingError: Error, LocalizedError {
        case changed(Int32)
        case invalidReadLimit

        var errorDescription: String? {
            switch self {
            case .changed(let code):
                return "the Voice Memo recording path changed or is no longer a safe owned file (errno \(code))"
            case .invalidReadLimit:
                return "the Voice Memo read limit is invalid"
            }
        }
    }

    private struct Identity: Sendable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
    }

    let url: URL
    private let directory: URL
    private let filename: String
    private let directoryIdentity: Identity
    private let fileIdentity: Identity

    var avAssetMIMEType: String? {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "qta", "mov": return "video/quicktime"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "aif", "aifc", "aiff": return "audio/aiff"
        default: return nil
        }
    }

    static func resolve(directory: URL, filename: String) -> SecureVoiceMemoRecording? {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/") else {
            return nil
        }

        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard directoryDescriptor >= 0 else { return nil }
        defer { Darwin.close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0,
              isSafeDirectory(directoryMetadata) else {
            return nil
        }

        let descriptor = filename.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var fileMetadata = stat()
        guard fstat(descriptor, &fileMetadata) == 0,
              isSafeRegular(fileMetadata) else {
            return nil
        }

        return SecureVoiceMemoRecording(
            url: directory.appendingPathComponent(filename, isDirectory: false),
            directory: directory,
            filename: filename,
            directoryIdentity: identity(directoryMetadata),
            fileIdentity: identity(fileMetadata)
        )
    }

    func fileSize() -> Int? {
        guard let descriptor = try? openVerifiedDescriptor() else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0 else {
            return nil
        }
        return Int(exactly: metadata.st_size)
    }

    /// Reads at most one byte beyond the cap from the already verified descriptor.
    func read(maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw RecordingError.invalidReadLimit
        }
        let descriptor = try openVerifiedDescriptor()
        defer { Darwin.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.read(upToCount: maximumBytes + 1) ?? Data()
    }

    func transcript() -> VoiceMemoTranscript? {
        guard let descriptor = try? openVerifiedDescriptor() else { return nil }
        defer { Darwin.close(descriptor) }
        return VoiceMemoTranscriptReader.read(fileDescriptor: descriptor)
    }

    func hasTranscript() -> Bool {
        transcript() != nil
    }

    /// Transfers ownership of a verified descriptor to an audio-input object. Deadline wrappers
    /// capture that object in their operation task, so the descriptor stays valid even if a native
    /// operation ignores cancellation after its caller has already returned.
    func openVerifiedAudioInput() throws -> VerifiedVoiceMemoAudioInput {
        let descriptor = try openVerifiedDescriptor()
        return VerifiedVoiceMemoAudioInput(
            descriptor: descriptor,
            mimeType: avAssetMIMEType
        )
    }

    private func openVerifiedDescriptor() throws -> Int32 {
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard directoryDescriptor >= 0 else {
            throw RecordingError.changed(errno)
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryMetadata = stat()
        guard fstat(directoryDescriptor, &directoryMetadata) == 0,
              Self.isSafeDirectory(directoryMetadata),
              Self.matches(directoryMetadata, directoryIdentity) else {
            throw RecordingError.changed(errno)
        }

        let descriptor = filename.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard descriptor >= 0 else {
            throw RecordingError.changed(errno)
        }

        var fileMetadata = stat()
        guard fstat(descriptor, &fileMetadata) == 0,
              Self.isSafeRegular(fileMetadata),
              Self.matches(fileMetadata, fileIdentity) else {
            let code = errno
            Darwin.close(descriptor)
            throw RecordingError.changed(code)
        }
        return descriptor
    }

    private static func isSafeDirectory(_ metadata: stat) -> Bool {
        metadata.st_uid == getuid()
            && metadata.st_mode & S_IFMT == S_IFDIR
    }

    private static func isSafeRegular(_ metadata: stat) -> Bool {
        metadata.st_uid == getuid()
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_nlink == 1
    }

    private static func identity(_ metadata: stat) -> Identity {
        Identity(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            owner: metadata.st_uid
        )
    }

    private static func matches(_ metadata: stat, _ identity: Identity) -> Bool {
        metadata.st_dev == identity.device
            && metadata.st_ino == identity.inode
            && metadata.st_uid == identity.owner
    }
}

/// Owns the descriptor backing a `/dev/fd` AVURLAsset. This is intentionally a reference type so
/// an unstructured deadline operation can retain the descriptor until native AVFoundation work
/// truly exits, independently of when the caller receives its timeout result.
final class VerifiedVoiceMemoAudioInput: @unchecked Sendable {
    let url: URL
    let mimeType: String?
    private let descriptor: Int32

    init(descriptor: Int32, mimeType: String?) {
        self.descriptor = descriptor
        self.mimeType = mimeType
        url = URL(fileURLWithPath: "/dev/fd/\(descriptor)", isDirectory: false)
    }

    deinit {
        Darwin.close(descriptor)
    }
}

/// Read-only access to the local Voice Memos library.
///
/// Voice Memos keeps its metadata in a Core Data SQLite store (`CloudRecordings.db`) next to the
/// `.m4a` recordings. Transcripts live inside the recordings themselves, so this provider reads the
/// store directly instead of driving Voice Memos.app through AppleEvents.
final class VoiceMemosProvider {
    static let maximumQueryUTF8Bytes = 4_096
    static let maximumMetadataFilenameBytes = 1_024
    static let maximumMetadataLabelBytes = 1_024
    static let maximumMetadataPathBytes = 4_096
    static let maximumReturnedTitleBytes = 1_024

    private let fileManager: FileManager
    private let storeOverrideForTesting: RecordingStore?
    private let sourceName = "Voice Memos"
    private let defaultBase64AudioBytes = 4_000_000
    private let maximumBase64AudioBytes = 5_000_000
    /// Even a transcript made entirely of JSON-escaped control characters remains comfortably
    /// below the bridge's 8 MiB response-body ceiling after the envelope is added.
    private let maximumReturnedTranscriptBytes = 750_000

    private let libraryPaths = [
        "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings",
        "Library/Application Support/com.apple.voicememos/Recordings",
        "Library/Containers/com.apple.VoiceMemos/Data/Library/Application Support/Recordings"
    ]
    private let databaseName = "CloudRecordings.db"

    init(
        fileManager: FileManager = .default,
        storeOverrideForTesting: (recordings: URL, database: URL)? = nil
    ) {
        self.fileManager = fileManager
        self.storeOverrideForTesting = storeOverrideForTesting.map {
            RecordingStore(recordings: $0.recordings, database: $0.database)
        }
    }

    // MARK: - Tools

    func search(input: [String: JSONValue]) async -> ToolResponse {
        let rawQuery = input.string("query")
        guard rawQuery.utf8.count <= Self.maximumQueryUTF8Bytes else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "query must not exceed \(Self.maximumQueryUTF8Bytes) UTF-8 bytes."
            )
        }
        let query = StringSanitizer.lower(rawQuery)
        let limit = max(1, min(input.int("limit", default: 25), 100))
        let offset = max(0, min(input.int("offset", default: 0), 1_000_000))
        let sinceDays = max(0, min(input.int("since_days", default: 0), 36_500))
        let transcribedOnly = input.bool("transcribed_only", default: false)
        let searchTranscripts = input.bool("search_transcripts", default: false)
        let includeTranscript = input.bool("include_transcript", default: false)
        let maxCandidates = max(limit, min(input.int("max_candidates", default: 300), 2_000))

        do {
            let store = try locateStore()
            let needsFileFilter = transcribedOnly || (searchTranscripts && !query.isEmpty)
            let fetchLimit = needsFileFilter ? maxCandidates : limit
            let fetchOffset = needsFileFilter ? 0 : offset

            let page = try withDatabase(at: store.database) { database -> RecordingPage in
                try readRecordings(
                    database: database,
                    store: store,
                    titleQuery: searchTranscripts ? "" : query,
                    sinceDays: sinceDays,
                    limit: fetchLimit,
                    offset: fetchOffset
                )
            }

            let readsTranscripts = needsFileFilter || includeTranscript
            var matches: [(row: RecordingRow, transcript: VoiceMemoTranscript?, hasTranscript: Bool)] = []

            for row in page.rows {
                let transcript = readsTranscripts ? row.transcript() : nil
                let hasTranscript = readsTranscripts ? (transcript != nil) : row.hasTranscript()

                if transcribedOnly, !hasTranscript {
                    continue
                }

                if searchTranscripts, !query.isEmpty {
                    let haystack = StringSanitizer.lower("\(row.title) \(transcript?.text ?? "")")
                    guard haystack.contains(query) else { continue }
                }

                matches.append((row: row, transcript: transcript, hasTranscript: hasTranscript))
            }

            let total = needsFileFilter ? matches.count : page.total
            let window = needsFileFilter ? Array(matches.dropFirst(offset).prefix(limit)) : matches

            let items = window.map { match in
                makeItem(
                    match.row,
                    transcript: includeTranscript ? match.transcript : nil,
                    hasTranscript: match.hasTranscript
                )
            }

            var message: String?
            if items.isEmpty {
                message = "No matching voice memos found."
            } else if total > items.count + offset {
                message = "Showing \(items.count) of \(total) matching voice memos. Use offset to page through the rest."
            } else if needsFileFilter, page.rows.count >= maxCandidates {
                message = "Inspected the \(maxCandidates) most recent recordings. Raise max_candidates to search further back."
            }

            return ToolResponse(ok: true, source: sourceName, items: items, message: message)
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    func read(input: [String: JSONValue]) async -> ToolResponse {
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: sourceName, message: "Missing required argument: id")
        }

        do {
            let row = try loadRecording(id: id)
            let transcript = row.transcript()
            return ToolResponse(ok: true, source: sourceName, items: [makeDetailItem(row, transcript: transcript)])
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    func transcript(input: [String: JSONValue]) async -> ToolResponse {
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: sourceName, message: "Missing required argument: id")
        }

        let format = input.string("format", default: "text")
        let validFormats = ["text", "timestamped", "json"]
        guard validFormats.contains(format) else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Invalid format '\(format)'. Valid values: \(validFormats.joined(separator: ", "))"
            )
        }

        do {
            let row = try loadRecording(id: id)
            guard let transcript = row.transcript() else {
                // No atom in the recording, but this app may have transcribed it before.
                if let cached = row.cachedTranscript() {
                    return transcriptResponse(
                        row: row,
                        text: cached,
                        origin: "cache",
                        locale: nil,
                        segments: [],
                        message: "This transcript was produced by voicememos_transcribe; macOS stored none in the recording, so there are no timestamps."
                    )
                }

                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "This recording carries no stored transcript. Open it in Voice Memos on macOS Sequoia or later to let macOS transcribe it, or call voicememos_transcribe."
                )
            }

            var metadata = baseMetadata(row)
            metadata["locale"] = transcript.locale
            metadata["segment_count"] = String(transcript.segments.count)
            metadata["format"] = format
            metadata["origin"] = "stored"

            let preview: String
            switch format {
            case "timestamped":
                preview = VoiceMemoTranscriptReader.timestampedText(transcript)
            case "json":
                preview = transcript.text
                if let encoded = encodeSegments(transcript.segments) {
                    addEncodedSegments(encoded, to: &metadata)
                }
            default:
                preview = transcript.text
            }

            let returnedPreview = boundedTranscript(preview, metadata: &metadata)
            let item = DataItem(
                id: row.id,
                title: row.title,
                subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
                kind: "voice_memo_transcript",
                source: sourceName,
                preview: returnedPreview,
                metadata: metadata
            )

            return ToolResponse(ok: true, source: sourceName, items: [item])
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    func audio(input: [String: JSONValue]) async -> ToolResponse {
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: sourceName, message: "Missing required argument: id")
        }

        let format = input.string("format", default: "path")
        let validFormats = ["path", "base64"]
        guard validFormats.contains(format) else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "Invalid format '\(format)'. Valid values: \(validFormats.joined(separator: ", "))"
            )
        }

        let maxBytes = max(
            1,
            min(input.int("max_bytes", default: defaultBase64AudioBytes), maximumBase64AudioBytes)
        )

        do {
            let row = try loadRecording(id: id)
            guard let recording = row.recording else {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "The recording file for '\(row.title)' is not on this Mac. It may still live in iCloud only."
                )
            }
            let fileURL = recording.url

            var metadata = baseMetadata(row)
            metadata["mime_type"] = mimeType(for: fileURL)
            metadata["format"] = format

            let size = recording.fileSize()
            if let size {
                metadata["bytes"] = String(size)
            }

            if format == "path" {
                let item = DataItem(
                    id: row.id,
                    title: row.title,
                    subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
                    kind: "voice_memo_audio",
                    source: sourceName,
                    preview: fileURL.path,
                    metadata: metadata
                )
                return ToolResponse(ok: true, source: sourceName, items: [item])
            }

            if let size, size > maxBytes {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "The recording is \(size) bytes and exceeds max_bytes (\(maxBytes)). Use format 'path', or raise max_bytes."
                )
            }

            guard let data = try? recording.read(maximumBytes: maxBytes) else {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "Cannot read \(fileURL.path). Grant Full Disk Access to M3MCP, then restart the app."
                )
            }

            guard data.count <= maxBytes else {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "The recording is \(data.count) bytes and exceeds max_bytes (\(maxBytes)). Use format 'path', or raise max_bytes."
                )
            }

            metadata["bytes"] = String(data.count)
            metadata["encoding"] = "base64"

            let item = DataItem(
                id: row.id,
                title: row.title,
                subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
                kind: "voice_memo_audio",
                source: sourceName,
                preview: data.base64EncodedString(),
                metadata: metadata
            )
            return ToolResponse(ok: true, source: sourceName, items: [item])
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    /// Produces a transcript, cheapest source first.
    ///
    /// 1. the transcript macOS stored inside the recording — free, and the only option before macOS 26
    /// 2. a transcript this app produced earlier, keyed on the recording's digest
    /// 3. `SpeechAnalyzer` on macOS 26, the engine Voice Memos itself uses
    /// 4. `SFSpeechRecognizer` below that, so macOS 15 to 25 can still transcribe
    func transcribe(input: [String: JSONValue]) async -> ToolResponse {
        let id = input.string("id")
        guard !id.isEmpty else {
            return ToolResponse(ok: false, source: sourceName, message: "Missing required argument: id")
        }

        let requestedLanguage = input.string("language").trimmingCharacters(in: .whitespacesAndNewlines)
        let language = requestedLanguage.isEmpty ? Locale.current.identifier : requestedLanguage
        let requestedTimeout = input.int(
            "timeout_seconds",
            default: VoiceMemoTranscriptionTimeoutPolicy.defaultSeconds
        )
        guard let timeoutSeconds = VoiceMemoTranscriptionTimeoutPolicy.validatedProviderSeconds(
            requestedTimeout
        ) else {
            return ToolResponse(
                ok: false,
                source: sourceName,
                message: "timeout_seconds must be between \(VoiceMemoTranscriptionTimeoutPolicy.minimumSeconds) and \(VoiceMemoTranscriptionTimeoutPolicy.maximumSeconds) inclusive."
            )
        }
        let timeout = TimeInterval(timeoutSeconds)
        let recognitionBudget = VoiceMemoTranscriptionBudget(seconds: timeout)
        let preferStored = input.bool("prefer_stored", default: true)

        do {
            let row = try loadRecording(id: id)

            if preferStored {
                if let stored = row.transcript() {
                    return transcriptResponse(
                        row: row,
                        text: stored.text,
                        origin: "stored",
                        locale: stored.locale,
                        segments: stored.segments,
                        message: "Returned the transcript macOS already stored in the recording. Set prefer_stored to false to re-run speech recognition."
                    )
                }

                if let cached = row.cachedTranscript() {
                    return transcriptResponse(
                        row: row,
                        text: cached,
                        origin: "cache",
                        locale: nil,
                        segments: [],
                        message: "Returned a transcript this app produced earlier. Set prefer_stored to false to re-run speech recognition."
                    )
                }
            }

            guard let recording = row.recording else {
                return ToolResponse(
                    ok: false,
                    source: sourceName,
                    message: "The recording file for '\(row.title)' is not on this Mac. It may still live in iCloud only."
                )
            }

            if SpeechTranscription.isSupported {
                do {
                    let analyzerBudget = recognitionBudget.remainingSeconds()
                    guard analyzerBudget > 0 else {
                        throw TranscriptionFailure.timedOut(timeout)
                    }
                    let audioInput = try recording.openVerifiedAudioInput()
                    let text = try await SpeechTranscription.transcribe(
                        input: audioInput,
                        locale: Locale(identifier: language),
                        budget: recognitionBudget
                    )
                    TranscriptCache.write(text, digest: row.digest)
                    return transcriptResponse(
                        row: row,
                        text: text,
                        origin: "speech_analyzer",
                        locale: language,
                        segments: [],
                        message: nil
                    )
                } catch let failure as TranscriptionFailure {
                    switch failure {
                    case .timedOut:
                        throw TranscriptionFailure.timedOut(timeout)
                    case .resourceBusy:
                        throw failure
                    default:
                        break
                    }
                    // Fall through to the older recognizer rather than failing outright: the model may
                    // simply be missing for this locale, which SFSpeechRecognizer can still cover.
                    AppLogger.log("SpeechAnalyzer unavailable, falling back: \(failure.localizedDescription)")
                }
            }

            let legacyBudget = recognitionBudget.remainingSeconds()
            guard legacyBudget > 0 else {
                throw TranscriptionFailure.timedOut(timeout)
            }
            let result: LegacySpeechRecognizer.Result
            do {
                let audioInput = try recording.openVerifiedAudioInput()
                result = try await LegacySpeechRecognizer.transcribe(
                    input: audioInput,
                    languageCode: language,
                    budget: recognitionBudget
                )
            } catch let failure as LegacySpeechRecognizer.Failure where failure.state == "timeout" {
                throw TranscriptionFailure.timedOut(timeout)
            }
            TranscriptCache.write(result.text, digest: row.digest)
            return transcriptResponse(
                row: row,
                text: result.text,
                origin: "speech_recognition",
                locale: result.locale,
                segments: result.segments,
                onDevice: result.onDevice,
                message: nil
            )
        } catch is CancellationError {
            return ToolResponse(ok: false, source: sourceName, message: "On-device speech transcription was cancelled.")
        } catch let failure as LegacySpeechRecognizer.Failure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch let failure as TranscriptionFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.localizedDescription)
        } catch let failure as VoiceMemoStoreFailure {
            return ToolResponse(ok: false, source: sourceName, message: failure.message)
        } catch {
            return ToolResponse(ok: false, source: sourceName, message: error.localizedDescription)
        }
    }

    private func transcriptResponse(
        row: RecordingRow,
        text: String,
        origin: String,
        locale: String?,
        segments: [VoiceMemoTranscript.Segment],
        onDevice: Bool? = nil,
        message: String?
    ) -> ToolResponse {
        var metadata = baseMetadata(row)
        metadata["origin"] = origin
        metadata["segment_count"] = String(segments.count)
        if let locale {
            metadata["locale"] = locale
        }
        if let onDevice {
            metadata["on_device"] = String(onDevice)
        }
        if !segments.isEmpty, let encoded = encodeSegments(segments) {
            addEncodedSegments(encoded, to: &metadata)
        }

        let returnedText = boundedTranscript(text, metadata: &metadata)
        let item = DataItem(
            id: row.id,
            title: row.title,
            subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
            kind: "voice_memo_transcript",
            source: sourceName,
            preview: returnedText,
            metadata: metadata
        )
        return ToolResponse(ok: true, source: sourceName, items: [item], message: message)
    }

    /// Reports whether the local Voice Memos store is readable, mirroring the Mail index preflight.
    func accessStatus() -> (state: String, message: String?) {
        do {
            let store = try locateStore()
            try withDatabase(at: store.database) { database in
                let columns = try tableColumns(database: database, table: "ZCLOUDRECORDING")
                guard !columns.isEmpty else {
                    throw VoiceMemoStoreFailure("The Voice Memos store is readable, but the ZCLOUDRECORDING table was not found.")
                }
            }
            return ("authorized", "Local Voice Memos store is readable.")
        } catch let failure as VoiceMemoStoreFailure {
            return ("manual", failure.message)
        } catch {
            return ("manual", error.localizedDescription)
        }
    }

    // MARK: - Model

    private struct RecordingStore {
        let recordings: URL
        let database: URL
    }

    private struct RecordingRow {
        let id: String
        let title: String
        let customLabel: String?
        let date: Date?
        let duration: Double
        let filename: String
        let recording: SecureVoiceMemoRecording?
        let deletedAt: Date?
        /// `ZAUDIODIGEST`, used as the transcript cache key.
        let digest: String?

        var fileURL: URL? { recording?.url }

        var subtitle: String {
            var parts: [String] = []
            if let date {
                parts.append(RecordingRow.displayFormatter.string(from: date))
            }
            if duration > 0 {
                parts.append(VoiceMemoTranscriptReader.timecode(duration))
            }
            return parts.joined(separator: " · ")
        }

        /// Transcript stored inside the recording by macOS, if any.
        func transcript() -> VoiceMemoTranscript? {
            recording?.transcript()
        }

        /// Transcript this app produced earlier, keyed on the recording's digest.
        func cachedTranscript() -> String? {
            TranscriptCache.read(digest: digest)
        }

        func hasTranscript() -> Bool {
            if recording?.hasTranscript() == true {
                return true
            }
            return TranscriptCache.has(digest: digest)
        }

        static let displayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()
    }

    private struct RecordingPage {
        let rows: [RecordingRow]
        let total: Int
    }

    private struct VoiceMemoStoreFailure: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }

    // MARK: - Item building

    private func makeItem(_ row: RecordingRow, transcript: VoiceMemoTranscript?, hasTranscript: Bool) -> DataItem {
        var metadata = baseMetadata(row)
        metadata["has_transcript"] = String(hasTranscript)

        if let transcript {
            metadata["locale"] = transcript.locale
            metadata["segment_count"] = String(transcript.segments.count)
        }

        return DataItem(
            id: row.id,
            title: row.title,
            subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
            kind: "voice_memo",
            source: sourceName,
            preview: transcript.map { StringSanitizer.compact($0.text, limit: 1_200) },
            metadata: metadata
        )
    }

    /// Detail item for `voicememos_read`: the full transcript instead of a snippet.
    private func makeDetailItem(_ row: RecordingRow, transcript: VoiceMemoTranscript?) -> DataItem {
        var metadata = baseMetadata(row)
        metadata["has_transcript"] = String(transcript != nil)

        if let transcript {
            metadata["locale"] = transcript.locale
            metadata["segment_count"] = String(transcript.segments.count)
        }

        let preview = transcript.map { boundedTranscript($0.text, metadata: &metadata) }

        return DataItem(
            id: row.id,
            title: row.title,
            subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
            kind: "voice_memo",
            source: sourceName,
            preview: preview,
            metadata: metadata
        )
    }

    private func baseMetadata(_ row: RecordingRow) -> [String: String] {
        var metadata: [String: String] = [
            "filename": Self.boundedOutput(
                row.filename,
                maximumBytes: Self.maximumMetadataFilenameBytes
            ),
            "duration_seconds": String(format: "%.1f", row.duration),
            "duration": VoiceMemoTranscriptReader.timecode(row.duration)
        ]

        if let date = row.date {
            metadata["date"] = ISO8601DateFormatter().string(from: date)
        }
        if let label = row.customLabel, !label.isEmpty {
            metadata["label"] = Self.boundedOutput(
                label,
                maximumBytes: Self.maximumMetadataLabelBytes
            )
        }
        if let fileURL = row.fileURL {
            metadata["path"] = Self.boundedOutput(
                fileURL.path,
                maximumBytes: Self.maximumMetadataPathBytes
            )
        } else {
            metadata["available_locally"] = "false"
        }

        return metadata
    }

    static func boundedOutput(_ value: String, maximumBytes: Int) -> String {
        M3InputValidation.boundedUTF8Prefix(
            value,
            maximumBytes: maximumBytes
        ).text
    }

    private func boundedTranscript(
        _ text: String,
        metadata: inout [String: String]
    ) -> String {
        let originalBytes = text.utf8.count
        let bounded = M3InputValidation.boundedUTF8Prefix(
            text,
            maximumBytes: maximumReturnedTranscriptBytes
        )
        metadata["content_bytes"] = String(originalBytes)
        metadata["returned_bytes"] = String(bounded.text.utf8.count)
        metadata["content_truncated"] = String(bounded.truncated)
        return bounded.text
    }

    struct EncodedSegments {
        let json: String
        let returned: Int
        let truncated: Bool
    }

    /// Builds a syntactically complete JSON array within the byte budget. It never returns an
    /// arbitrary String prefix, and stops serializing as soon as the next whole segment would not
    /// fit.
    func encodeSegments(
        _ segments: [VoiceMemoTranscript.Segment],
        maximumBytes: Int = 40_000
    ) -> EncodedSegments? {
        guard maximumBytes >= 2 else { return nil }
        var data = Data("[".utf8)
        var returned = 0

        for segment in segments {
            // Avoid allocating JSON proportional to an attacker-controlled multi-megabyte segment
            // that can never fit in this metadata field.
            let boundedText = M3InputValidation.boundedUTF8Prefix(
                segment.text,
                maximumBytes: maximumBytes
            ).text
            let object: [String: Any] = [
                "text": boundedText,
                "start": segment.start,
                "end": segment.end
            ]
            guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                break
            }
            let separatorBytes = returned == 0 ? 0 : 1
            guard data.count + separatorBytes + encoded.count + 1 <= maximumBytes else {
                break
            }
            if returned > 0 { data.append(0x2C) }
            data.append(encoded)
            returned += 1
        }

        data.append(0x5D)
        guard let json = String(data: data, encoding: .utf8) else { return nil }
        return EncodedSegments(
            json: json,
            returned: returned,
            truncated: returned < segments.count
        )
    }

    private func addEncodedSegments(
        _ encoded: EncodedSegments,
        to metadata: inout [String: String]
    ) {
        metadata["segments_json"] = encoded.json
        metadata["segments_returned"] = String(encoded.returned)
        metadata["segments_truncated"] = String(encoded.truncated)
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "aifc", "aiff": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Store access

    private func locateStore() throws -> RecordingStore {
        if let storeOverrideForTesting {
            return storeOverrideForTesting
        }
        let home = fileManager.homeDirectoryForCurrentUser

        for relativePath in libraryPaths {
            let recordings = home.appendingPathComponent(relativePath, isDirectory: true)
            let database = recordings.appendingPathComponent(databaseName, isDirectory: false)
            if fileManager.fileExists(atPath: database.path) {
                return RecordingStore(recordings: recordings, database: database)
            }
        }

        let primary = home.appendingPathComponent(libraryPaths[0], isDirectory: true)
        if fileManager.fileExists(atPath: primary.path) {
            throw VoiceMemoStoreFailure("The Voice Memos recordings folder exists, but \(databaseName) is missing. Open Voice Memos once so macOS creates its store.")
        }

        throw VoiceMemoStoreFailure("The Voice Memos store was not found below \(primary.path). Open Voice Memos at least once, and grant Full Disk Access to M3MCP if the folder is protected.")
    }

    private func loadRecording(id: String) throws -> RecordingRow {
        guard M3InputValidation.isCanonicalPositiveDecimal(id) else {
            throw VoiceMemoStoreFailure("Voice Memo id must be a canonical positive decimal value returned by voicememos_search.")
        }
        let store = try locateStore()
        return try withDatabase(at: store.database) { database -> RecordingRow in
            guard let row = try readRecording(database: database, store: store, id: id) else {
                throw VoiceMemoStoreFailure("No voice memo with id \(id). Run voicememos_search to list current ids.")
            }
            return row
        }
    }

    private func readRecordings(
        database: OpaquePointer,
        store: RecordingStore,
        titleQuery: String,
        sinceDays: Int,
        limit: Int,
        offset: Int
    ) throws -> RecordingPage {
        let schema = try recordingSchema(database: database)

        var conditions: [String] = []
        var textBindings: [String] = []
        var dateBinding: Double?

        // Rows without a file name are placeholders the Voice Memos UI does not show either.
        if let pathColumn = schema.path {
            conditions.append("(\(quote(pathColumn)) IS NOT NULL AND TRIM(\(quote(pathColumn))) != '')")
        }

        // ZEVICTIONDATE marks the start of the Recently Deleted window, not an iCloud eviction.
        if let evictionColumn = schema.evictionDate {
            conditions.append("\(quote(evictionColumn)) IS NULL")
        }

        if !titleQuery.isEmpty {
            var titleConditions: [String] = []
            for column in [schema.label, schema.title, schema.path].compactMap({ $0 }) {
                titleConditions.append("\(quote(column)) LIKE ?")
                textBindings.append("%\(titleQuery)%")
            }
            if !titleConditions.isEmpty {
                conditions.append("(\(titleConditions.joined(separator: " OR ")))")
            }
        }

        if sinceDays > 0, let dateColumn = schema.date {
            let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86_400)
            conditions.append("\(quote(dateColumn)) >= ?")
            dateBinding = cutoff.timeIntervalSinceReferenceDate
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let orderColumn = schema.date ?? "Z_PK"
        let selectList = selectClause(for: schema)

        let total = try countRecordings(
            database: database,
            whereClause: whereClause,
            textBindings: textBindings,
            dateBinding: dateBinding
        )

        let sql = """
        SELECT \(selectList)
        FROM ZCLOUDRECORDING
        \(whereClause)
        ORDER BY \(quote(orderColumn)) DESC
        LIMIT ? OFFSET ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VoiceMemoStoreFailure("Could not query the Voice Memos store: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for value in textBindings {
            sqlite3_bind_text(statement, bindIndex, value, -1, transientDestructor())
            bindIndex += 1
        }
        if let dateBinding {
            sqlite3_bind_double(statement, bindIndex, dateBinding)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))
        bindIndex += 1
        sqlite3_bind_int(statement, bindIndex, Int32(offset))

        var rows: [RecordingRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                rows.append(try makeRow(statement: statement, store: store))
            } else if status == SQLITE_DONE {
                break
            } else {
                throw VoiceMemoStoreFailure(
                    "Could not read bounded Voice Memos rows: \(databaseMessage(database))"
                )
            }
        }

        return RecordingPage(rows: rows, total: total)
    }

    private func countRecordings(
        database: OpaquePointer,
        whereClause: String,
        textBindings: [String],
        dateBinding: Double?
    ) throws -> Int {
        let sql = "SELECT COUNT(*) FROM ZCLOUDRECORDING \(whereClause)"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VoiceMemoStoreFailure("Could not count voice memos: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for value in textBindings {
            sqlite3_bind_text(statement, bindIndex, value, -1, transientDestructor())
            bindIndex += 1
        }
        if let dateBinding {
            sqlite3_bind_double(statement, bindIndex, dateBinding)
        }

        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            if status != SQLITE_DONE {
                throw VoiceMemoStoreFailure(
                    "Could not count bounded Voice Memos rows: \(databaseMessage(database))"
                )
            }
            return 0
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func readRecording(database: OpaquePointer, store: RecordingStore, id: String) throws -> RecordingRow? {
        let schema = try recordingSchema(database: database)
        let selectList = selectClause(for: schema)

        let sql = "SELECT \(selectList) FROM ZCLOUDRECORDING WHERE Z_PK = ? LIMIT 1"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VoiceMemoStoreFailure("Could not query the Voice Memos store: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, transientDestructor())

        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            if status != SQLITE_DONE {
                throw VoiceMemoStoreFailure(
                    "Could not read the bounded Voice Memo row: \(databaseMessage(database))"
                )
            }
            return nil
        }

        return try makeRow(statement: statement, store: store)
    }

    private func makeRow(statement: OpaquePointer, store: RecordingStore) throws -> RecordingRow {
        let id = String(sqlite3_column_int64(statement, 0))
        let path = try textValue(
            statement,
            column: 1,
            field: "ZPATH",
            maximumBytes: VoiceMemoSQLiteValuePolicy.maximumPathBytes
        ) ?? ""
        let label = try textValue(
            statement,
            column: 2,
            field: "ZCUSTOMLABEL",
            maximumBytes: VoiceMemoSQLiteValuePolicy.maximumLabelBytes
        )
        let storedTitle = try textValue(
            statement,
            column: 3,
            field: "ZTITLE",
            maximumBytes: VoiceMemoSQLiteValuePolicy.maximumTitleBytes
        )
        let date = dateValue(statement, column: 4)
        let duration = doubleValue(statement, column: 5) ?? 0
        let deletedAt = dateValue(statement, column: 6)
        let digest: String?
        if sqlite3_column_type(statement, 7) == SQLITE_BLOB {
            digest = blobHexValue(statement, column: 7)
        } else {
            digest = try textValue(
                statement,
                column: 7,
                field: "ZAUDIODIGEST",
                maximumBytes: VoiceMemoSQLiteValuePolicy.maximumDigestTextBytes
            )
        }

        let filename = path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent
        let recording = resolveRecording(path: path, store: store)

        let fallbackTitle = filename.isEmpty
            ? "Voice Memo \(id)"
            : URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent

        let title = [label, storedTitle]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? fallbackTitle

        return RecordingRow(
            id: id,
            title: Self.boundedOutput(
                StringSanitizer.compact(title, limit: 200),
                maximumBytes: Self.maximumReturnedTitleBytes
            ),
            customLabel: label,
            date: date,
            duration: duration,
            filename: filename,
            recording: recording,
            deletedAt: deletedAt,
            digest: digest
        )
    }

    /// `ZPATH` is normally a bare filename, but older stores wrote absolute paths. Only the final
    /// filename is used: a database value must never turn Full Disk Access into an arbitrary path
    /// read, and a symlink at the expected recording location is rejected.
    private func resolveRecording(
        path: String,
        store: RecordingStore
    ) -> SecureVoiceMemoRecording? {
        guard !path.isEmpty else {
            return nil
        }

        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        return SecureVoiceMemoRecording.resolve(
            directory: store.recordings,
            filename: filename
        )
    }

    private struct RecordingSchema {
        let path: String?
        let label: String?
        let title: String?
        let date: String?
        let duration: String?
        let evictionDate: String?
        let digest: String?
    }

    private func selectClause(for schema: RecordingSchema) -> String {
        [
            quote("Z_PK"),
            schema.path.map(quote) ?? "NULL",
            schema.label.map(quote) ?? "NULL",
            schema.title.map(quote) ?? "NULL",
            schema.date.map(quote) ?? "NULL",
            schema.duration.map(quote) ?? "NULL",
            schema.evictionDate.map(quote) ?? "NULL",
            schema.digest.map(quote) ?? "NULL"
        ].joined(separator: ", ")
    }

    private func recordingSchema(database: OpaquePointer) throws -> RecordingSchema {
        let columns = try tableColumns(database: database, table: "ZCLOUDRECORDING")
        guard !columns.isEmpty else {
            throw VoiceMemoStoreFailure("The Voice Memos store does not contain a ZCLOUDRECORDING table.")
        }

        return RecordingSchema(
            path: pick(columns, ["ZPATH", "ZUNIQUEID"]),
            label: pick(columns, ["ZCUSTOMLABEL", "ZCUSTOMLABELFORSORTING"]),
            title: pick(columns, ["ZENCRYPTEDTITLE", "ZTITLE"]),
            date: pick(columns, ["ZDATE", "ZCREATIONDATE"]),
            duration: pick(columns, ["ZDURATION"]),
            evictionDate: pick(columns, ["ZEVICTIONDATE"]),
            digest: pick(columns, ["ZAUDIODIGEST"])
        )
    }

    // MARK: - SQLite helpers

    /// Runs `body` against a private copy of the store.
    ///
    /// `CloudRecordings.db` runs in WAL mode, and the log routinely holds the newest recordings.
    /// Opening the live file directly would race Voice Memos while it updates the store. The private
    /// copy includes the existing WAL/SHM set, which SQLite can replay read-only without ever writing
    /// either the live store or the copied database.
    /// Internal seams allow deterministic security tests to place the snapshot in an isolated
    /// directory and mutate it at the exact post-query boundary. Production callers use defaults.
    func withDatabase<T>(
        at url: URL,
        temporaryDirectory: URL? = nil,
        postReadValidationHook: ((URL) -> Void)? = nil,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        let snapshot = try makeSnapshot(
            of: url,
            temporaryDirectory: temporaryDirectory ?? fileManager.temporaryDirectory
        )
        defer { try? snapshot.cleanup() }
        guard snapshot.validateBeforeOpen() else {
            throw VoiceMemoStoreFailure(
                "The private Voice Memos snapshot changed before SQLite could open it."
            )
        }

        var database: OpaquePointer?
        // A synthetic uncheckpointed-WAL fixture verifies that this platform can replay the copied
        // WAL/SHM set under READONLY. SQLITE_OPEN_NOFOLLOW independently rejects symlink traversal
        // in SQLite's VFS; the inode checks on both sides of open detect parent/path replacement.
        let status = sqlite3_open_v2(
            snapshot.database.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )

        guard status == SQLITE_OK, let database else {
            let message = database.map(databaseMessage) ?? "OSStatus \(status)"
            if let database {
                sqlite3_close(database)
            }
            throw VoiceMemoStoreFailure("Cannot read the Voice Memos store. Grant Full Disk Access to M3MCP, then restart the app. Detail: \(message)")
        }

        defer { sqlite3_close(database) }
        VoiceMemoSQLiteValuePolicy.applyConnectionLimit(to: database)
        sqlite3_busy_timeout(database, 800)

        // Force SQLite to open and parse the main DB plus any copied WAL/SHM before the second
        // inode/content-metadata validation, then keep that read transaction pinned for every query
        // in `body`. A final validation after `body` detects ordinary in-place writes during reads.
        guard sqlite3_exec(database, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
            throw VoiceMemoStoreFailure(
                "Could not begin a read-only Voice Memos snapshot transaction: \(databaseMessage(database))"
            )
        }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        var probe: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT rootpage FROM sqlite_schema LIMIT 1",
            -1,
            &probe,
            nil
        ) == SQLITE_OK, let probe else {
            throw VoiceMemoStoreFailure(
                "Could not validate the copied Voice Memos schema: \(databaseMessage(database))"
            )
        }
        let probeStatus = sqlite3_step(probe)
        sqlite3_finalize(probe)
        guard probeStatus == SQLITE_ROW || probeStatus == SQLITE_DONE else {
            throw VoiceMemoStoreFailure(
                "Could not read the copied Voice Memos schema: \(databaseMessage(database))"
            )
        }
        guard snapshot.validateAfterOpen() else {
            throw VoiceMemoStoreFailure(
                "The private Voice Memos snapshot changed while SQLite opened it."
            )
        }
        let result = try body(database)
        postReadValidationHook?(snapshot.database)
        guard snapshot.validateAfterRead() else {
            throw VoiceMemoStoreFailure(
                "The private Voice Memos snapshot changed while SQLite read it."
            )
        }
        return result
    }

    /// Copies the store plus its write-ahead log into a private directory.
    private func makeSnapshot(
        of url: URL,
        temporaryDirectory: URL
    ) throws -> SecureVoiceMemoStoreSnapshot {
        do {
            return try SecureVoiceMemoStoreSnapshot.create(
                sourceDatabase: url,
                temporaryDirectory: temporaryDirectory
            )
        } catch {
            throw VoiceMemoStoreFailure(
                "Cannot prepare a safe temporary copy of the Voice Memos store at \(url.path). "
                    + "Grant Full Disk Access to M3MCP, then restart the app. "
                    + "Detail: \(error.localizedDescription)"
            )
        }
    }

    private func tableColumns(database: OpaquePointer, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VoiceMemoStoreFailure("Could not inspect the Voice Memos schema: \(databaseMessage(database))")
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                if let name = try textValue(
                    statement,
                    column: 1,
                    field: "schema column name",
                    maximumBytes: VoiceMemoSQLiteValuePolicy.maximumSchemaIdentifierBytes
                ) {
                    columns.insert(name)
                }
            } else if status == SQLITE_DONE {
                break
            } else {
                throw VoiceMemoStoreFailure(
                    "Could not read the bounded Voice Memos schema: \(databaseMessage(database))"
                )
            }
        }
        return columns
    }

    private func pick(_ columns: Set<String>, _ names: [String]) -> String? {
        for name in names where columns.contains(name) {
            return name
        }
        return nil
    }

    private func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func textValue(
        _ statement: OpaquePointer,
        column: Int32,
        field: String,
        maximumBytes: Int
    ) throws -> String? {
        try VoiceMemoSQLiteValuePolicy.text(
            statement,
            column: column,
            field: field,
            maximumBytes: maximumBytes
        )
    }

    /// `ZAUDIODIGEST` is a BLOB; its hex form is stable and makes a usable cache key.
    private func blobHexValue(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else {
            return nil
        }

        let count = Int(sqlite3_column_bytes(statement, column))
        guard count == 32,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return UnsafeRawBufferPointer(start: bytes, count: count)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func doubleValue(_ statement: OpaquePointer, column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, column)
    }

    /// Core Data stores timestamps as seconds since 2001-01-01, so they map onto the reference date.
    private func dateValue(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard let value = doubleValue(statement, column: column), value != 0 else {
            return nil
        }

        if value > 1_000_000_000 {
            return Date(timeIntervalSince1970: value)
        }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    private func databaseMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private func transientDestructor() -> sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
