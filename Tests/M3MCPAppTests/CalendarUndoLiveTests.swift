import EventKit
import Foundation
import M3MCPCore
import XCTest
@testable import M3MCPApp

/// The half of the undo contract that only a real calendar can answer: does a deleted event come
/// back, and does a changed one go back.
///
/// Two conditions, both required, neither of them prompting:
///
/// - `M3MCP_CALENDAR_UNDO_LIVE=1`, because this writes to the machine's Calendar database and nobody
///   should discover that by running `swift test`.
/// - Calendar authorization already granted. The status is read, never requested: a test that raises
///   a TCC panel would hang a CI runner and pester a developer.
///
/// Everything happens inside a calendar this test creates in the local ("On My Mac") source and
/// removes again, so it never touches an account that syncs and never an event that was already
/// there. Without a local source the test skips rather than fall back to a synced account.
final class CalendarUndoLiveTests: XCTestCase {
    private static let environmentKey = "M3MCP_CALENDAR_UNDO_LIVE"
    private static let calendarTitle = "M3MCP Undo Verification"

    private var store: EKEventStore!
    private var calendar: EKCalendar!
    private var provider: CalendarProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()

        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.environmentKey] == "1",
            "Live calendar round trip is opt-in. Set \(Self.environmentKey)=1 to write to the real Calendar database."
        )
        try XCTSkipUnless(
            EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            "Calendar authorization is \(Self.statusName). This test reads the status and never requests it, so grant full access in System Settings first."
        )

        store = EKEventStore()
        guard let localSource = store.sources.first(where: { $0.sourceType == .local }) else {
            throw XCTSkip("No local calendar source, and this test refuses to write into a synced account.")
        }

        let created = EKCalendar(for: .event, eventStore: store)
        created.title = Self.calendarTitle
        created.source = localSource
        try store.saveCalendar(created, commit: true)
        calendar = created
        provider = CalendarProvider()
    }

    override func tearDownWithError() throws {
        if let calendar, let store {
            try? store.removeCalendar(calendar, commit: true)
        }
        provider = nil
        calendar = nil
        store = nil
        try super.tearDownWithError()
    }

    private static var statusName: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "full access"
        case .writeOnly: return "write only"
        @unknown default: return "unrecognised"
        }
    }

    private func createEvent(title: String) async throws -> (id: String, undoToken: String) {
        let response = await provider.createEvent(input: [
            "title": .string(title),
            "start": .string("2031-04-07T09:00:00+02:00"),
            "duration_minutes": .number(45),
            "location": .string("Room 3"),
            "notes": .string("live undo verification"),
            "calendar_id": .string(calendar.calendarIdentifier)
        ])

        XCTAssertTrue(response.ok, response.message ?? "")
        let id = try XCTUnwrap(response.items.first?.id)
        let token = try XCTUnwrap(response.meta?["undo_token"])
        return (id, token)
    }

    func testADeletedEventComesBackWithItsContentAndANewIdentifier() async throws {
        let created = try await createEvent(title: "Delete and restore")
        let before = try XCTUnwrap(store.event(withIdentifier: created.id))
        let title = before.title
        let start = before.startDate
        let end = before.endDate
        let location = before.location

        let deletion = await provider.deleteEvent(input: ["id": .string(created.id)])
        XCTAssertTrue(deletion.ok, deletion.message ?? "")
        XCTAssertNil(store.event(withIdentifier: created.id), "the delete must really have happened")

        let token = try XCTUnwrap(deletion.meta?["undo_token"])
        XCTAssertEqual(deletion.meta?["undo_restores_identifier"], "false")

        let undo = await provider.undoWrite(input: ["undo_token": .string(token)])
        XCTAssertTrue(undo.ok, undo.message ?? "")

        let restoredID = try XCTUnwrap(undo.items.first?.id)
        XCTAssertNotEqual(restoredID, created.id, "EventKit cannot return the old identifier")

        let restored = try XCTUnwrap(store.event(withIdentifier: restoredID))
        XCTAssertEqual(restored.title, title)
        XCTAssertEqual(restored.startDate, start)
        XCTAssertEqual(restored.endDate, end)
        XCTAssertEqual(restored.location, location)
        XCTAssertEqual(restored.calendar.calendarIdentifier, calendar.calendarIdentifier)

        // Single use: the token is spent and a replay must not remove the restored event.
        let replay = await provider.undoWrite(input: ["undo_token": .string(token)])
        XCTAssertFalse(replay.ok)
        XCTAssertNotNil(store.event(withIdentifier: restoredID))
    }

    func testAChangedEventGoesBackToItsPreviousValues() async throws {
        let created = try await createEvent(title: "Update and restore")

        let update = await provider.updateEvent(input: [
            "id": .string(created.id),
            "title": .string("Changed by mistake"),
            "location": .string("Room 9")
        ])
        XCTAssertTrue(update.ok, update.message ?? "")

        let changed = try XCTUnwrap(store.event(withIdentifier: created.id))
        XCTAssertEqual(changed.title, "Changed by mistake")
        XCTAssertEqual(changed.location, "Room 9")

        let token = try XCTUnwrap(update.meta?["undo_token"])
        XCTAssertEqual(update.meta?["undo_restores_identifier"], "true")

        let undo = await provider.undoWrite(input: ["undo_token": .string(token)])
        XCTAssertTrue(undo.ok, undo.message ?? "")

        let restored = try XCTUnwrap(store.event(withIdentifier: created.id))
        XCTAssertEqual(restored.title, "Update and restore")
        XCTAssertEqual(restored.location, "Room 3")
        // A field the update never touched must not be dragged along by the undo.
        XCTAssertEqual(restored.notes, "live undo verification")
    }

    func testAPreviewLeavesTheCalendarExactlyAsItWas() async throws {
        let created = try await createEvent(title: "Preview only")

        let deletePreview = await provider.deleteEvent(input: [
            "id": .string(created.id),
            "dry_run": .bool(true)
        ])
        XCTAssertTrue(deletePreview.ok, deletePreview.message ?? "")
        XCTAssertEqual(deletePreview.meta?["dry_run"], "true")
        XCTAssertNil(deletePreview.meta?["undo_token"])
        XCTAssertNotNil(store.event(withIdentifier: created.id), "a preview must not delete")

        let updatePreview = await provider.updateEvent(input: [
            "id": .string(created.id),
            "title": .string("Not written"),
            "dry_run": .bool(true)
        ])
        XCTAssertTrue(updatePreview.ok, updatePreview.message ?? "")
        XCTAssertEqual(updatePreview.meta?["would_change"], "title")

        let untouched = try XCTUnwrap(store.event(withIdentifier: created.id))
        XCTAssertEqual(untouched.title, "Preview only", "a preview must not write, not even in memory")

        let createPreview = await provider.createEvent(input: [
            "title": .string("Never created"),
            "start": .string("2031-04-08T09:00:00+02:00"),
            "duration_minutes": .number(30),
            "calendar_id": .string(calendar.calendarIdentifier),
            "dry_run": .bool(true)
        ])
        XCTAssertTrue(createPreview.ok, createPreview.message ?? "")
        XCTAssertNil(createPreview.meta?["undo_token"])

        let search = await provider.search(input: [
            "query": .string("Never created"),
            "calendar": .string(calendar.calendarIdentifier),
            "start_days": .number(-3_650),
            "end_days": .number(3_650)
        ])
        XCTAssertTrue(search.items.isEmpty, "a previewed create must leave nothing behind")
    }

    func testACreatedEventCanBeTakenBack() async throws {
        let created = try await createEvent(title: "Created by mistake")
        XCTAssertNotNil(store.event(withIdentifier: created.id))

        let undo = await provider.undoWrite(input: ["undo_token": .string(created.undoToken)])
        XCTAssertTrue(undo.ok, undo.message ?? "")
        XCTAssertNil(store.event(withIdentifier: created.id), "undoing a create must remove the event")
    }
}
