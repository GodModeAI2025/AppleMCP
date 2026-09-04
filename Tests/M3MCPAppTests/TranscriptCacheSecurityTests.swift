import Darwin
import Foundation
import XCTest
@testable import M3MCPApp

final class TranscriptCacheSecurityTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testCacheRejectsTranscriptDirectorySymlinkWithoutTouchingTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base", isDirectory: true)
        let appDirectory = base.appendingPathComponent("M3MCP", isDirectory: true)
        let protectedTarget = root.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protectedTarget, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedTarget.path)
        try FileManager.default.createSymbolicLink(
            at: appDirectory.appendingPathComponent("transcripts"),
            withDestinationURL: protectedTarget
        )

        TranscriptCache.write("must not escape", digest: digest, baseDirectory: base)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: protectedTarget.appendingPathComponent("\(digest).txt").path
            )
        )
        XCTAssertEqual(try permissions(of: protectedTarget), 0o755)
        XCTAssertNil(TranscriptCache.read(digest: digest, baseDirectory: base))
    }

    func testCacheCreatesOwnerOnlyDirectoriesAndFileAndReadsItBack() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)

        TranscriptCache.write("Grüße", digest: digest.uppercased(), baseDirectory: base)

        let appDirectory = base.appendingPathComponent("M3MCP", isDirectory: true)
        let cacheDirectory = appDirectory.appendingPathComponent("transcripts", isDirectory: true)
        let cacheFile = cacheDirectory.appendingPathComponent("\(digest).txt")
        XCTAssertEqual(try permissions(of: appDirectory), 0o700)
        XCTAssertEqual(try permissions(of: cacheDirectory), 0o700)
        XCTAssertEqual(try permissions(of: cacheFile), 0o600)
        XCTAssertEqual(TranscriptCache.read(digest: digest, baseDirectory: base), "Grüße")
    }

    func testCacheReplacementDoesNotFollowExistingFileSymlink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        TranscriptCache.write("first", digest: digest, baseDirectory: base)

        let cacheFile = base
            .appendingPathComponent("M3MCP/transcripts", isDirectory: true)
            .appendingPathComponent("\(digest).txt")
        try FileManager.default.removeItem(at: cacheFile)
        let target = root.appendingPathComponent("unrelated.txt")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: cacheFile, withDestinationURL: target)

        TranscriptCache.write("replacement", digest: digest, baseDirectory: base)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
        XCTAssertEqual(TranscriptCache.read(digest: digest, baseDirectory: base), "replacement")
        var metadata = stat()
        XCTAssertEqual(lstat(cacheFile.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
    }

    private func makeRoot() throws -> URL {
        let root = URL(
            fileURLWithPath: "/private/tmp/m3cache-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func permissions(of url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return metadata.st_mode & 0o777
    }
}
