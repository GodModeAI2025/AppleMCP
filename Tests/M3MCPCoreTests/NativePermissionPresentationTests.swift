import XCTest
@testable import M3MCPCore

final class NativePermissionPresentationTests: XCTestCase {
    private func item(_ id: String, _ state: String) -> DataItem {
        DataItem(id: id, title: id, kind: "permission", source: "Permissions", metadata: ["state": state])
    }

    func testConfirmedEventKitGrantSurvivesStalePreflightAndRequiresRestart() {
        var model = NativePermissionPresentation()
        model.received(item("calendar", "authorized"))
        let result = model.reconcile([item("calendar", "not_determined")])[0]
        XCTAssertEqual(result.metadata["state"], "authorized")
        XCTAssertEqual(result.metadata["restart_required"], "true")
        XCTAssertEqual(model.reconcile([item("calendar", "not_determined")])[0].metadata["restart_required"], "true")
    }

    func testFreshGrantClearsPendingRestart() {
        var model = NativePermissionPresentation()
        model.received(item("reminders", "authorized"))
        let result = model.reconcile([item("reminders", "authorized")])[0]
        XCTAssertEqual(result.metadata["state"], "authorized")
        XCTAssertNil(result.metadata["restart_required"])
    }

    func testRevocationWinsOverEarlierGrantedCallback() {
        for denied in ["denied", "restricted", "write_only"] {
            var model = NativePermissionPresentation()
            model.received(item("calendar", "authorized"))
            XCTAssertEqual(model.reconcile([item("calendar", denied)])[0].metadata["state"], denied)
            XCTAssertEqual(model.reconcile([item("calendar", "not_determined")])[0].metadata["state"], "not_determined")
        }
    }

    func testNoInventedGrantsAndErrorsAreNotDiscarded() {
        var model = NativePermissionPresentation()
        XCTAssertEqual(model.reconcile([item("calendar", "not_determined")])[0].metadata["state"], "not_determined")
        model.received(item("calendar", "error"))
        let result = model.reconcile([item("calendar", "not_determined")])[0]
        XCTAssertEqual(result.metadata["state"], "error")
        XCTAssertNil(result.metadata["restart_required"])
    }
}
