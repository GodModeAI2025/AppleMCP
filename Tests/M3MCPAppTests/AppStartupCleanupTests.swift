import Foundation
import XCTest
@testable import M3MCPApp

final class AppStartupCleanupTests: XCTestCase {
    func testProviderConstructionPreservesStaleArtifactUntilExplicitAppStartupCleanup() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/m3-startup-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let artifact = root.appendingPathComponent(
            "M3MCP-VoiceMemos-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -(25 * 60 * 60))],
            ofItemAtPath: artifact.path
        )

        let fileManager = IsolatedTemporaryFileManager(root: root)
        _ = VoiceMemosProvider(fileManager: fileManager)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))

        let result = AppStartupCleanup.run(in: root, fileManager: fileManager)
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
    }

    @MainActor
    func testLifecycleTaskStartsAtMostOnceAndPropagatesCancellation() async {
        let probe = StartupCleanupProbe()
        let lifecycleTask = AppStartupCleanupTask { isCancelled in
            probe.markStarted()
            while !isCancelled() {
                usleep(1_000)
            }
            probe.markCancelled()
        }

        XCTAssertFalse(lifecycleTask.hasStarted)
        XCTAssertEqual(probe.startCount, 0)

        lifecycleTask.startIfNeeded()
        lifecycleTask.startIfNeeded()
        await waitUntil { probe.startCount == 1 }

        XCTAssertTrue(lifecycleTask.hasStarted)
        XCTAssertEqual(probe.startCount, 1)
        lifecycleTask.cancel()
        await lifecycleTask.waitForCompletion()

        XCTAssertEqual(probe.startCount, 1)
        XCTAssertTrue(probe.sawCancellation)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }
}

private final class IsolatedTemporaryFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override var temporaryDirectory: URL { root }
}

private final class StartupCleanupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var cancelled = false

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var sawCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func markStarted() {
        lock.lock()
        starts += 1
        lock.unlock()
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
