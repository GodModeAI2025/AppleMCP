import Darwin
import Foundation
import XCTest

import M3MCPCore

final class SensitiveTemporaryArtifactsTests: XCTestCase {
    private let ownerID = UInt32(getuid())
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testPolicyAcceptsOnlyExactOwnedStaleNamesAndTypes() {
        let stale = now.addingTimeInterval(-SensitiveTemporaryArtifacts.defaultStaleAge - 1)
        let uuid = "01234567-89AB-CDEF-0123-456789ABCDEF"

        XCTAssertTrue(shouldRemove(name: "M3MCP-VoiceMemos-\(uuid)", type: .directory, owner: ownerID, date: stale))
        XCTAssertTrue(shouldRemove(name: "m3mcp-transcode-\(uuid).caf", type: .regularFile, owner: ownerID, date: stale))
        XCTAssertTrue(shouldRemove(name: "m3mcp-image-\(uuid).png", type: .regularFile, owner: ownerID, date: stale))
        XCTAssertTrue(shouldRemove(name: "m3mcp-shortcut-input-\(uuid).json", type: .regularFile, owner: ownerID, date: stale))

        XCTAssertFalse(shouldRemove(name: "M3MCP-VoiceMemos-\(uuid)-extra", type: .directory, owner: ownerID, date: stale))
        XCTAssertFalse(shouldRemove(name: "m3mcp-transcode-\(uuid).caf.bak", type: .regularFile, owner: ownerID, date: stale))
        XCTAssertFalse(shouldRemove(name: "m3mcp-transcode-not-a-uuid.caf", type: .regularFile, owner: ownerID, date: stale))
        XCTAssertFalse(shouldRemove(name: "m3mcp-image-\(uuid).png.bak", type: .regularFile, owner: ownerID, date: stale))
        XCTAssertFalse(shouldRemove(name: "M3MCP-VoiceMemos-\(uuid)", type: .regularFile, owner: ownerID, date: stale))
        XCTAssertFalse(shouldRemove(name: "m3mcp-transcode-\(uuid).caf", type: .symbolicLink, owner: ownerID, date: stale))
        XCTAssertFalse(shouldRemove(name: "M3MCP-VoiceMemos-\(uuid)", type: .directory, owner: ownerID &+ 1, date: stale))
        XCTAssertFalse(shouldRemove(name: "M3MCP-VoiceMemos-\(uuid)", type: .directory, owner: ownerID, date: now))
    }

    func testCleanupRemovesOnlyMatchingStaleFilesystemEntries() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SensitiveTemporaryArtifactsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let oldCAF = directory.appendingPathComponent("m3mcp-transcode-11111111-1111-1111-1111-111111111111.caf")
        let oldSnapshot = directory.appendingPathComponent("M3MCP-VoiceMemos-22222222-2222-2222-2222-222222222222", isDirectory: true)
        let oldImage = directory.appendingPathComponent("m3mcp-image-77777777-7777-7777-7777-777777777777.png")
        let youngCAF = directory.appendingPathComponent("m3mcp-transcode-33333333-3333-3333-3333-333333333333.caf")
        let wrongName = directory.appendingPathComponent("m3mcp-transcode-44444444-4444-4444-4444-444444444444.caf.backup")
        let wrongType = directory.appendingPathComponent("M3MCP-VoiceMemos-55555555-5555-5555-5555-555555555555")
        let symlink = directory.appendingPathComponent("m3mcp-transcode-66666666-6666-6666-6666-666666666666.caf")
        let symlinkTarget = directory.appendingPathComponent("target-must-survive")

        XCTAssertTrue(fileManager.createFile(atPath: oldCAF.path, contents: Data("audio".utf8)))
        try fileManager.createDirectory(at: oldSnapshot, withIntermediateDirectories: false)
        XCTAssertTrue(fileManager.createFile(atPath: oldImage.path, contents: Data("image".utf8)))
        XCTAssertTrue(fileManager.createFile(atPath: youngCAF.path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: wrongName.path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: wrongType.path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: symlinkTarget.path, contents: Data("keep".utf8)))
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)

        let old = Date(timeIntervalSince1970: 1_000_000_000)
        for url in [oldCAF, oldSnapshot, oldImage, wrongName, wrongType, symlinkTarget] {
            try fileManager.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: youngCAF.path)

        let result = SensitiveTemporaryArtifacts.removeStale(
            in: directory,
            fileManager: fileManager,
            ownerID: ownerID,
            now: now,
            staleAge: 60
        )

        XCTAssertEqual(result.inspectedCount, 8)
        XCTAssertEqual(result.removedCount, 3)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertFalse(result.entryLimitReached)
        XCTAssertFalse(result.removalLimitReached)
        XCTAssertFalse(result.cancelled)
        XCTAssertFalse(fileManager.fileExists(atPath: oldCAF.path))
        XCTAssertFalse(fileManager.fileExists(atPath: oldSnapshot.path))
        XCTAssertFalse(fileManager.fileExists(atPath: oldImage.path))
        XCTAssertTrue(fileManager.fileExists(atPath: youngCAF.path))
        XCTAssertTrue(fileManager.fileExists(atPath: wrongName.path))
        XCTAssertTrue(fileManager.fileExists(atPath: wrongType.path))
        XCTAssertTrue(fileManager.fileExists(atPath: symlink.path))
        XCTAssertTrue(fileManager.fileExists(atPath: symlinkTarget.path))
    }

    func testCleanupStopsAtHardEntryBudgetWithoutMaterializingDirectory() throws {
        let fileManager = EnumerationRejectingFileManager()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SensitiveTemporaryArtifactsBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<12 {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: directory.appendingPathComponent("unrelated-\(index)").path,
                contents: Data()
            ))
        }

        let result = SensitiveTemporaryArtifacts.removeStale(
            in: directory,
            fileManager: fileManager,
            maximumEntries: 3
        )

        XCTAssertEqual(result.inspectedCount, 3)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertTrue(result.entryLimitReached)
        XCTAssertFalse(result.removalLimitReached)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(fileManager.materializingEnumerationCallCount, 0)
    }

    func testCleanupStopsAtIndependentRemovalBudget() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SensitiveTemporaryArtifactsRemovalBudget-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }

        let old = Date(timeIntervalSince1970: 1_000_000_000)
        for index in 0..<5 {
            let identifier = String(format: "00000000-0000-0000-0000-%012d", index)
            let artifact = directory.appendingPathComponent("m3mcp-image-\(identifier).png")
            XCTAssertTrue(fileManager.createFile(atPath: artifact.path, contents: Data()))
            try fileManager.setAttributes([.modificationDate: old], ofItemAtPath: artifact.path)
        }

        let result = SensitiveTemporaryArtifacts.removeStale(
            in: directory,
            fileManager: fileManager,
            ownerID: ownerID,
            now: now,
            staleAge: 60,
            maximumEntries: 10,
            maximumRemovals: 2
        )

        XCTAssertEqual(result.inspectedCount, 2)
        XCTAssertEqual(result.removedCount, 2)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertFalse(result.entryLimitReached)
        XCTAssertTrue(result.removalLimitReached)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: directory.path).count, 3)
    }

    func testCleanupHonorsCancellationBeforeInspectingAnEntry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SensitiveTemporaryArtifactsCancelled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: directory.appendingPathComponent("unrelated").path,
            contents: Data()
        ))

        let result = SensitiveTemporaryArtifacts.removeStale(in: directory, isCancelled: { true })

        XCTAssertEqual(result.inspectedCount, 0)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.entryLimitReached)
        XCTAssertFalse(result.removalLimitReached)
    }

    private func shouldRemove(
        name: String,
        type: SensitiveTemporaryArtifacts.EntryType,
        owner: UInt32,
        date: Date
    ) -> Bool {
        SensitiveTemporaryArtifacts.shouldRemove(
            .init(name: name, type: type, ownerID: owner, modificationDate: date),
            ownerID: ownerID,
            now: now
        )
    }
}

private final class EnumerationRejectingFileManager: FileManager {
    private(set) var materializingEnumerationCallCount = 0

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        materializingEnumerationCallCount += 1
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}
