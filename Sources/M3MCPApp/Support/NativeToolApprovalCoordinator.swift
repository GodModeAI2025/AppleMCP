import AppKit
import Foundation
import M3MCPCore

/// Presents one-shot, local approval sheets for tools whose effects extend beyond read-only access.
///
/// All state is main-actor isolated. A FIFO queue means concurrent MCP calls can never stack or
/// race approval dialogs, and every queued call receives its own decision. Each call's timeout
/// starts when it is enqueued, so contention cannot extend the maximum wait. Closing the sheet,
/// cancelling the waiting task, timing out, or lacking a usable app window all deny the call.
@MainActor
final class NativeToolApprovalCoordinator {
    private struct PendingRequest {
        let id: UUID
        let request: M3MCPToolApprovalRequest
        let continuation: CheckedContinuation<Bool, Never>
        let cancellation: ApprovalCancellationState
    }

    private static let defaultTimeout: TimeInterval = 30
    private static let maximumTimeout: TimeInterval = 60

    private let timeoutNanoseconds: UInt64
    private let beforeContinuationInstallation: (@MainActor () async -> Void)?
    private let enqueueObserver: (@MainActor () -> Void)?
    private var queue: [PendingRequest] = []
    private var activeRequest: PendingRequest?
    private var activeAlert: NSAlert?
    private var expirationTasks: [UUID: Task<Void, Never>] = [:]

    init(
        timeout: TimeInterval = 30,
        beforeContinuationInstallation: (@MainActor () async -> Void)? = nil,
        enqueueObserver: (@MainActor () -> Void)? = nil
    ) {
        let finiteTimeout = timeout.isFinite ? timeout : Self.defaultTimeout
        let boundedTimeout = min(max(finiteTimeout, 1), Self.maximumTimeout)
        timeoutNanoseconds = UInt64(boundedTimeout * 1_000_000_000)
        self.beforeContinuationInstallation = beforeContinuationInstallation
        self.enqueueObserver = enqueueObserver
    }

    func requestApproval(for request: M3MCPToolApprovalRequest) async -> Bool {
        guard !Task.isCancelled else { return false }

        await beforeContinuationInstallation?()
        let id = UUID()
        let cancellation = ApprovalCancellationState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(PendingRequest(
                    id: id,
                    request: request,
                    continuation: continuation,
                    cancellation: cancellation
                ))
            }
        } onCancel: { [weak self] in
            // This flag is set synchronously, before the main-actor cancellation task can race an
            // as-yet-uninstalled continuation. `enqueue` observes it and resumes false without ever
            // presenting UI; if enqueue won first, cancel(id:) removes/dismisses that request.
            cancellation.cancel()
            Task { @MainActor in
                self?.cancel(id: id)
            }
        }
    }

    private func enqueue(_ pending: PendingRequest) {
        guard !Task.isCancelled, !pending.cancellation.isCancelled else {
            pending.continuation.resume(returning: false)
            return
        }
        enqueueObserver?()
        queue.append(pending)
        expirationTasks[pending.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            expire(id: pending.id)
        }
        presentNextIfPossible()
    }

    private func presentNextIfPossible() {
        guard activeRequest == nil else { return }

        while !queue.isEmpty {
            let pending = queue.removeFirst()
            guard !pending.cancellation.isCancelled else {
                expirationTasks.removeValue(forKey: pending.id)?.cancel()
                pending.continuation.resume(returning: false)
                continue
            }
            guard let application = NSApp, application.isRunning,
                  let window = approvalWindow(in: application) else {
                expirationTasks.removeValue(forKey: pending.id)?.cancel()
                pending.continuation.resume(returning: false)
                continue
            }

            let alert = makeAlert(for: pending.request)
            guard !pending.cancellation.isCancelled else {
                expirationTasks.removeValue(forKey: pending.id)?.cancel()
                pending.continuation.resume(returning: false)
                continue
            }
            activeRequest = pending
            activeAlert = alert

            application.activate(ignoringOtherApps: true)
            alert.beginSheetModal(for: window) { [weak self] response in
                Task { @MainActor in
                    self?.finish(
                        id: pending.id,
                        approved: response == .alertSecondButtonReturn,
                        dismissSheet: false
                    )
                }
            }
            return
        }
    }

    private func approvalWindow(in application: NSApplication) -> NSWindow? {
        application.keyWindow
            ?? application.mainWindow
            ?? application.windows.first(where: { $0.isVisible && $0.canBecomeKey })
    }

    private func makeAlert(for request: M3MCPToolApprovalRequest) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Approve one call to \(request.tool.rawValue)?"
        alert.informativeText = """
        A local MCP client requested this operation.

        Tool
        \(request.tool.rawValue)

        Arguments
        \(request.argumentPreview)

        Allow applies to this call only. Deny is the default.
        """

        let denyButton = alert.addButton(withTitle: "Deny")
        denyButton.keyEquivalent = "\r"
        let allowButton = alert.addButton(withTitle: "Allow This Call")
        allowButton.keyEquivalent = ""
        return alert
    }

    private func cancel(id: UUID) {
        if activeRequest?.id == id {
            finish(id: id, approved: false, dismissSheet: true)
            return
        }

        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let pending = queue.remove(at: index)
        expirationTasks.removeValue(forKey: id)?.cancel()
        pending.continuation.resume(returning: false)
    }

    private func expire(id: UUID) {
        if activeRequest?.id == id {
            finish(id: id, approved: false, dismissSheet: true)
            return
        }

        guard let index = queue.firstIndex(where: { $0.id == id }) else {
            expirationTasks.removeValue(forKey: id)
            return
        }
        let pending = queue.remove(at: index)
        expirationTasks.removeValue(forKey: id)
        pending.continuation.resume(returning: false)
    }

    private func finish(id: UUID, approved: Bool, dismissSheet: Bool) {
        guard let pending = activeRequest, pending.id == id else { return }

        let alert = activeAlert
        activeRequest = nil
        activeAlert = nil
        expirationTasks.removeValue(forKey: id)?.cancel()

        if dismissSheet, let alert {
            if let parent = alert.window.sheetParent {
                parent.endSheet(alert.window, returnCode: .abort)
            } else {
                alert.window.orderOut(nil)
            }
        }

        pending.continuation.resume(returning: approved)
        presentNextIfPossible()
    }
}

/// Thread-safe cancellation memory for the race before a main-actor approval request is enqueued.
private final class ApprovalCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
