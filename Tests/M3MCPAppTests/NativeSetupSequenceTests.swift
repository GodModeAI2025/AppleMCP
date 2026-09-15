import XCTest
@testable import M3MCPApp

final class NativeSetupSequenceTests: XCTestCase {
    @MainActor
    func testAllSourcesRemainSequencedWhenFolderIsSkippedAndSecondRunIsRequested() async {
        let model = AppModel()
        var visited: [String] = []
        var refreshed = false
        await model.runDataPermissionSequence(performStep: { id in
            XCTAssertTrue(model.permissionBusy)
            XCTAssertTrue(model.permissionSequenceRunning)
            visited.append(id)
            if id == "mail_local_store" {
                // A cancelled picker returns without a grant. Reentrant clicks must not start
                // another sequence while this stage owns the UI.
                await model.runDataPermissionSequence(performStep: { _ in
                    XCTFail("Concurrent sequence opened another permission dialog")
                }, refresh: { XCTFail("Concurrent sequence refreshed state") })
            }
        }, refresh: {
            XCTAssertTrue(model.permissionBusy)
            refreshed = true
        })
        XCTAssertEqual(visited, ["calendar", "contacts", "reminders", "mail_local_store",
                                 "notes_automation", "photos", "voice_memos_store", "speech_recognition"])
        XCTAssertTrue(refreshed)
        XCTAssertFalse(model.permissionBusy)
        XCTAssertFalse(model.permissionSequenceRunning)
    }

    @MainActor
    func testStopAfterFolderStagePreservesCompletedStepsAndReleasesBusyState() async {
        let model = AppModel()
        var visited: [String] = []
        var refreshes = 0
        await model.runDataPermissionSequence(performStep: { id in
            visited.append(id)
            if id == "mail_local_store" { model.cancelPermissionSequence() }
        }, refresh: { refreshes += 1 })
        XCTAssertEqual(visited, ["calendar", "contacts", "reminders", "mail_local_store"])
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(model.permissionBusy)
        XCTAssertFalse(model.permissionSequenceRunning)
        XCTAssertTrue(model.permissionProgress?.contains("Ablauf beendet") == true)

        visited.removeAll()
        await model.runDataPermissionSequence(performStep: { visited.append($0) }, refresh: {})
        XCTAssertEqual(visited.count, 8, "A deliberate later run must reset the stop request")
    }
}
