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
/// Everything goes through one `CalendarProvider`, and therefore one `EKEventStore`, including the
/// setup and the read-backs. Reading through a second store instance would leave the result
/// depending on when EventKit propagates a save between stores, which is a property of the framework
/// and not of this code.
///
/// The scratch calendar is created by `calendar_create_calendar`, which defaults to the local
/// ("On My Mac") source, so nothing here reaches an account that syncs. Without a local source the
/// tool refuses and this test skips.
final class CalendarUndoLiveTests: XCTestCase {
    private static let environmentKey = "M3MCP_CALENDAR_UNDO_LIVE"
    private static let calendarTitle = "M3MCP Undo Verification"

    private var provider: CalendarProvider!
    private var calendarID: String!

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.environmentKey] == "1",
            "Live calendar round trip is opt-in. Set \(Self.environmentKey)=1 to write to the real Calendar database."
        )
        try XCTSkipUnless(
            EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            "Calendar authorization is \(Self.statusName). This test reads the status and never requests it, so grant full access in System Settings first."
        )

        provider = CalendarProvider()

        // A leftover calendar from an interrupted run would make the create fail on the duplicate
        // title, so it is removed first.
        await removeScratchCalendar()

        let created = await provider.createCalendar(input: [
            "title": .string(Self.calendarTitle)
        ])
        guard created.ok, let id = created.items.first?.id else {
            throw XCTSkip("Could not create a local scratch calendar: \(created.message ?? "no message")")
        }
        calendarID = id
    }

    override func tearDown() async throws {
        if provider != nil {
            await removeScratchCalendar()
        }
        provider = nil
        calendarID = nil
        try await super.tearDown()
    }

    private func removeScratchCalendar() async {
        let listed = await provider.listCalendars(input: ["query": .string(Self.calendarTitle)])
        for item in listed.items where item.title == Self.calendarTitle {
            _ = await provider.deleteCalendar(input: [
                "id": .string(item.id),
                "title": .string(Self.calendarTitle)
            ])
        }
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
            "calendar_id": .string(calendarID)
        ])

        XCTAssertTrue(response.ok, response.message ?? "")
        let id = try XCTUnwrap(response.items.first?.id)
        let token = try XCTUnwrap(response.meta?["undo_token"])
        return (id, token)
    }

    /// Read-back through the same provider, so the assertions are about the write and not about
    /// cross-store propagation.
    private func readEvent(_ id: String) async -> DataItem? {
        let response = await provider.readEvent(input: ["id": .string(id)])
        return response.ok ? response.items.first : nil
    }

    func testADeletedEventComesBackWithItsContentAndANewIdentifier() async throws {
        let created = try await createEvent(title: "Delete and restore")
        let beforeItem = await readEvent(created.id)
        let before = try XCTUnwrap(beforeItem)

        let deletion = await provider.deleteEvent(input: ["id": .string(created.id)])
        XCTAssertTrue(deletion.ok, deletion.message ?? "")
        let gone = await readEvent(created.id)
        XCTAssertNil(gone, "the delete must really have happened")

        let token = try XCTUnwrap(deletion.meta?["undo_token"])
        XCTAssertEqual(deletion.meta?["undo_restores_identifier"], "false")

        let undo = await provider.undoWrite(input: ["undo_token": .string(token)])
        XCTAssertTrue(undo.ok, undo.message ?? "")

        let restoredID = try XCTUnwrap(undo.items.first?.id)
        XCTAssertNotEqual(restoredID, created.id, "EventKit cannot return the old identifier")

        let restoredItem = await readEvent(restoredID)
        let restored = try XCTUnwrap(restoredItem)
        XCTAssertEqual(restored.title, before.title)
        XCTAssertEqual(restored.metadata["start"], before.metadata["start"])
        XCTAssertEqual(restored.metadata["end"], before.metadata["end"])
        XCTAssertEqual(restored.subtitle, before.subtitle, "location")
        XCTAssertEqual(restored.metadata["calendar_id"], calendarID)

        // Single use: the token is spent and a replay must not remove the restored event.
        let replay = await provider.undoWrite(input: ["undo_token": .string(token)])
        XCTAssertFalse(replay.ok)
        let survived = await readEvent(restoredID)
        XCTAssertNotNil(survived)
    }

    func testAChangedEventGoesBackToItsPreviousValues() async throws {
        let created = try await createEvent(title: "Update and restore")

        let update = await provider.updateEvent(input: [
            "id": .string(created.id),
            "title": .string("Changed by mistake"),
            "location": .string("Room 9")
        ])
        XCTAssertTrue(update.ok, update.message ?? "")

        let changedItem = await readEvent(created.id)
        let changed = try XCTUnwrap(changedItem)
        XCTAssertEqual(changed.title, "Changed by mistake")
        XCTAssertEqual(changed.subtitle, "Room 9")

        let token = try XCTUnwrap(update.meta?["undo_token"])
        XCTAssertEqual(update.meta?["undo_restores_identifier"], "true")

        let undo = await provider.undoWrite(input: ["undo_token": .string(token)])
        XCTAssertTrue(undo.ok, undo.message ?? "")

        let restoredItem = await readEvent(created.id)
        let restored = try XCTUnwrap(restoredItem)
        XCTAssertEqual(restored.title, "Update and restore")
        XCTAssertEqual(restored.subtitle, "Room 3")
        // A field the update never touched must not be dragged along by the undo.
        XCTAssertEqual(restored.preview, "live undo verification")
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
        let stillThere = await readEvent(created.id)
        XCTAssertNotNil(stillThere, "a preview must not delete")

        let updatePreview = await provider.updateEvent(input: [
            "id": .string(created.id),
            "title": .string("Not written"),
            "dry_run": .bool(true)
        ])
        XCTAssertTrue(updatePreview.ok, updatePreview.message ?? "")
        XCTAssertEqual(updatePreview.meta?["would_change"], "title")

        let untouchedItem = await readEvent(created.id)
        let untouched = try XCTUnwrap(untouchedItem)
        XCTAssertEqual(untouched.title, "Preview only", "a preview must not write, not even in memory")

        let createPreview = await provider.createEvent(input: [
            "title": .string("Never created"),
            "start": .string("2031-04-08T09:00:00+02:00"),
            "duration_minutes": .number(30),
            "calendar_id": .string(calendarID),
            "dry_run": .bool(true)
        ])
        XCTAssertTrue(createPreview.ok, createPreview.message ?? "")
        XCTAssertNil(createPreview.meta?["undo_token"])

        let search = await provider.search(input: [
            "query": .string("Never created"),
            "calendar": .string(calendarID),
            "start_days": .number(-3_650),
            "end_days": .number(3_650)
        ])
        XCTAssertTrue(search.items.isEmpty, "a previewed create must leave nothing behind")
    }

    func testACreatedEventCanBeTakenBack() async throws {
        let created = try await createEvent(title: "Created by mistake")
        let present = await readEvent(created.id)
        XCTAssertNotNil(present)

        let undo = await provider.undoWrite(input: ["undo_token": .string(created.undoToken)])
        XCTAssertTrue(undo.ok, undo.message ?? "")
        let gone = await readEvent(created.id)
        XCTAssertNil(gone, "undoing a create must remove the event")
    }
}
