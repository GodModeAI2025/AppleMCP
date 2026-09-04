import Foundation
import M3MCPCore

/// Keeps deletion of narrowly matched stale app artifacts at the native application lifecycle
/// boundary. Read-only providers and status tools deliberately do not invoke this maintenance.
enum AppStartupCleanup {
    @discardableResult
    static func run(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        maximumEntries: Int = SensitiveTemporaryArtifacts.maximumEntriesPerPass,
        maximumRemovals: Int = SensitiveTemporaryArtifacts.maximumRemovalsPerPass,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> SensitiveTemporaryArtifacts.CleanupResult {
        let cleanup = SensitiveTemporaryArtifacts.removeStale(
            in: temporaryDirectory,
            fileManager: fileManager,
            maximumEntries: maximumEntries,
            maximumRemovals: maximumRemovals,
            isCancelled: isCancelled
        )
        if cleanup.removedCount > 0 || cleanup.failedCount > 0 ||
            cleanup.entryLimitReached || cleanup.removalLimitReached || cleanup.cancelled {
            AppLogger.log(
                "App startup cleanup inspected \(cleanup.inspectedCount), removed \(cleanup.removedCount), " +
                "failed \(cleanup.failedCount), entryLimitReached=\(cleanup.entryLimitReached), " +
                "removalLimitReached=\(cleanup.removalLimitReached), cancelled=\(cleanup.cancelled)."
            )
        }
        return cleanup
    }
}

/// Owns the single best-effort cleanup job for one native app lifecycle. Work starts only when the
/// app explicitly asks after its socket-start attempt, runs off the main actor, and observes task
/// cancellation between directory entries and removal attempts.
@MainActor
final class AppStartupCleanupTask {
    typealias Operation = @Sendable (@escaping @Sendable () -> Bool) -> Void

    private let operation: Operation
    private var task: Task<Void, Never>?
    private(set) var hasStarted = false

    init(operation: @escaping Operation = { isCancelled in
        AppStartupCleanup.run(isCancelled: isCancelled)
    }) {
        self.operation = operation
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        let operation = self.operation
        task = Task.detached(priority: .utility) {
            operation { Task.isCancelled }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func waitForCompletion() async {
        await task?.value
    }

    deinit {
        task?.cancel()
    }
}
