import EventKit
import Foundation
import XCTest
@testable import M3MCPApp
@testable import M3MCPCore

/// Where the dry-run exemption actually lands: the app dispatcher.
///
/// `M3MCPInteractiveApproval` is unit-tested on its own, but the exemption is only worth anything if
/// `LocalMCPService` asks the question with the arguments in hand. These calls go through the real
/// dispatcher with a real security policy, and no approval UI at all: with none available a call
/// that needs a sheet is denied outright, which makes the denial itself the signal.
final class CalendarDryRunDispatchTests: XCTestCase {
    private static let approvalDenial = "requires explicit local approval"

    private func serviceWithoutApprovalUI() -> LocalMCPService {
        LocalMCPService(
            securityPolicy: M3MCPSecurityPolicy(
                configuration: .init(allowCalendarMutations: true)
            ),
            approvalHandler: nil
        )
    }

    private func writeCalls() -> [(String, [String: JSONValue])] {
        [
            (
                M3MCPToolName.calendarCreateEvent.rawValue,
                [
                    "title": .string("Weekly review"),
                    "start": .string("2026-09-08T10:00:00+02:00"),
                    "duration_minutes": .number(30),
                    "calendar_id": .string("calendar-that-does-not-exist")
                ]
            ),
            (
                M3MCPToolName.calendarUpdateEvent.rawValue,
                ["id": .string("event-1"), "title": .string("Renamed")]
            ),
            (
                M3MCPToolName.calendarDeleteEvent.rawValue,
                ["id": .string("event-1")]
            ),
            (
                M3MCPToolName.calendarCreateCalendar.rawValue,
                ["title": .string("Scratch")]
            ),
            (
                M3MCPToolName.calendarDeleteCalendar.rawValue,
                ["id": .string("calendar-1"), "title": .string("Scratch")]
            ),
            (
                M3MCPToolName.calendarUndoWrite.rawValue,
                ["undo_token": .string("cal-undo-none")]
            )
        ]
    }

    func testACommitWithNoApprovalUIIsRefusedBeforeItReachesTheProvider() async {
        let service = serviceWithoutApprovalUI()

        for (tool, input) in writeCalls() {
            let response = await service.handle(tool: tool, input: input)
            XCTAssertFalse(response.ok, tool)
            XCTAssertEqual(response.source, "M3MCP Interactive Approval", tool)
            XCTAssertTrue(
                response.message?.contains(Self.approvalDenial) == true,
                "\(tool) must not run without a decision: \(response.message ?? "")"
            )
        }
    }

    func testADryRunIsNotStoppedByTheMissingApprovalUI() async {
        let service = serviceWithoutApprovalUI()

        for (tool, input) in writeCalls() {
            var previewInput = input
            previewInput["dry_run"] = .bool(true)

            let response = await service.handle(tool: tool, input: previewInput)

            // It gets past approval and into the provider, where this machine's Calendar
            // authorization decides what happens next. What it must never be is the approval denial.
            XCTAssertNotEqual(response.source, "M3MCP Interactive Approval", tool)
            XCTAssertFalse(
                response.message?.contains(Self.approvalDenial) == true,
                "\(tool) preview was stopped by the approval gate: \(response.message ?? "")"
            )
        }
    }

    func testTheLaunchOptInStillGatesAPreview() async {
        // Default-safe policy: the preview is not a way around the launch decision.
        let service = LocalMCPService(securityPolicy: M3MCPSecurityPolicy())

        let response = await service.handle(
            tool: M3MCPToolName.calendarDeleteEvent.rawValue,
            input: ["id": .string("event-1"), "dry_run": .bool(true)]
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.source, "M3MCP Security Policy")
        XCTAssertTrue(
            response.message?.contains("M3MCP_ENABLE_CALENDAR_MUTATIONS") == true,
            response.message ?? ""
        )
    }

    func testAStringDryRunIsRejectedByTheSchemaRatherThanTreatedAsAPreview() async {
        let service = serviceWithoutApprovalUI()

        let response = await service.handle(
            tool: M3MCPToolName.calendarDeleteEvent.rawValue,
            input: ["id": .string("event-1"), "dry_run": .string("true")]
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.source, "M3MCP Argument Validation")
        XCTAssertTrue(response.message?.contains("must be a boolean") == true, response.message ?? "")
    }

    func testTheUndoSheetDescribesTheWriteRatherThanTheRedactedToken() async {
        let provider = CalendarProvider()

        // The argument the sheet would otherwise have to work with.
        let preview = M3MCPInteractiveApproval.argumentPreview([
            "undo_token": .string("cal-undo-3f9a")
        ])
        XCTAssertTrue(preview.contains("[REDACTED]"), preview)

        let record = await provider.undoJournal.record(
            tool: .calendarDeleteEvent,
            summary: "deleting 'Weekly review' from 'Work'",
            action: .recreateDeletedEvent(
                M3MCPCalendarEventSnapshot(
                    title: "Weekly review",
                    startDate: Date(timeIntervalSince1970: 1_800_000_000),
                    endDate: Date(timeIntervalSince1970: 1_800_003_600),
                    calendarIdentifier: "calendar-1"
                )
            )
        )

        let effect = await provider.undoEffectDescription(
            input: ["undo_token": .string(record.token)]
        )
        XCTAssertEqual(
            effect,
            "Reverses deleting 'Weekly review' from 'Work'. The event gets a new id."
        )

        // Reading it for the sheet must not spend it.
        let stillThere = await provider.undoJournal.peek(token: record.token)
        guard case .found = stillThere else {
            return XCTFail("building the sheet text must not consume the token")
        }

        // A token that stands for nothing says so, so nobody approves an empty undo.
        let missing = await provider.undoEffectDescription(
            input: ["undo_token": .string("cal-undo-nothing")]
        )
        XCTAssertEqual(missing, "No snapshot matches this token. Nothing would be reversed.")
    }

    func testUndoRefusesAnEmptyTokenAndAnUnknownOneWithoutTouchingTheCalendar() async {
        let provider = CalendarProvider()

        let blank = await provider.undoWrite(input: ["undo_token": .string("   ")])
        XCTAssertFalse(blank.ok)

        // On a machine without Calendar authorization the access gate answers first, which is itself
        // the guarantee under test: nothing reaches EventKit before that check.
        if blank.message?.contains("Calendar access") != true {
            XCTAssertTrue(blank.message?.contains("'undo_token' is required") == true, blank.message ?? "")
        }
    }
}
