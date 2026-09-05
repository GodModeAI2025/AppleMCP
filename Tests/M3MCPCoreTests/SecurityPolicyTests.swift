import XCTest
@testable import M3MCPCore

final class SecurityPolicyTests: XCTestCase {
    typealias Classification = M3MCPSecurityPolicy.ToolClassification

    func testEveryToolHasAnExplicitReviewedClassification() {
        let expected: [M3MCPToolName: Classification] = [
            .sourceStatus: .readOnly,
            .permissionsStatus: .readOnly,
            .permissionsRequest: .permissionUI,
            .permissionsOpenSettings: .permissionUI,

            .calendarSearch: .readOnly,
            .calendarReadEvent: .readOnly,
            .calendarListCalendars: .readOnly,
            .calendarCreateEvent: .calendarMutation,
            .calendarUpdateEvent: .calendarMutation,
            .calendarDeleteEvent: .calendarMutation,
            .calendarCreateCalendar: .calendarMutation,
            .calendarDeleteCalendar: .calendarMutation,
            .calendarUndoWrite: .calendarMutation,

            .contactsSearch: .readOnly,
            .mailSearch: .readOnly,
            .mailListMailboxes: .readOnly,
            .mailRead: .readOnly,
            .remindersSearch: .readOnly,
            .notesSearch: .readOnly,
            .notesRead: .readOnly,
            .photosSearch: .readOnly,
            .photosAlbums: .readOnly,
            .voiceMemosSearch: .readOnly,
            .voiceMemosRead: .readOnly,
            .voiceMemosTranscript: .readOnly,
            .voiceMemosAudio: .readOnly,
            .voiceMemosTranscribe: .localProcessing,

            .aiSummarize: .localProcessing,
            .aiWritingTools: .userShortcut,
            .aiTranslate: .userShortcut,
            .aiImagePlayground: .localGeneration
        ]

        XCTAssertEqual(M3MCPToolName.allCases.count, 31)
        XCTAssertEqual(Set(expected.keys), Set(M3MCPToolName.allCases))
        XCTAssertEqual(
            M3MCPSecurityPolicy.knownToolNames,
            Set(expected.keys.map(\.rawValue))
        )

        for tool in M3MCPToolName.allCases {
            XCTAssertEqual(
                M3MCPSecurityPolicy.classification(of: tool),
                expected[tool],
                "Unexpected classification for \(tool.rawValue)"
            )
            XCTAssertEqual(
                M3MCPSecurityPolicy.classification(ofToolNamed: tool.rawValue),
                expected[tool]
            )
        }

        XCTAssertNil(M3MCPSecurityPolicy.classification(ofToolNamed: "future_unreviewed_tool"))
    }

    func testDefaultSafeProfileExposesOnlyReviewedNonPrivilegedTools() {
        let policy = M3MCPSecurityPolicy()
        let expectedDenied: Set<M3MCPToolName> = [
            .permissionsRequest,
            .permissionsOpenSettings,
            .calendarCreateEvent,
            .calendarUpdateEvent,
            .calendarDeleteEvent,
            .calendarCreateCalendar,
            .calendarDeleteCalendar,
            .calendarUndoWrite,
            .aiWritingTools,
            .aiTranslate
        ]

        XCTAssertEqual(Set(M3MCPToolName.allCases.filter { !policy.allows($0) }), expectedDenied)
        XCTAssertEqual(M3MCPToolName.allCases.filter(policy.allows).count, 21)
        XCTAssertFalse(policy.allows(toolNamed: "future_unreviewed_tool"))

        // These are intentionally retained: status and reads are observational, summarization is
        // on-device processing, and Image Playground uses the local ImageCreator implementation.
        XCTAssertTrue(policy.allows(.sourceStatus))
        XCTAssertTrue(policy.allows(.permissionsStatus))
        XCTAssertTrue(policy.allows(.mailRead))
        XCTAssertTrue(policy.allows(.aiSummarize))
        XCTAssertTrue(policy.allows(.aiImagePlayground))
    }

    func testToolAvailabilityIsACompleteCatalogFreeUIPolicyProjection() {
        let policy = M3MCPSecurityPolicy()
        let rows = policy.toolAvailability

        XCTAssertEqual(rows.map(\.tool), M3MCPToolName.allCases)
        XCTAssertEqual(rows.count, 31)
        XCTAssertEqual(rows.filter(\.isEnabled).count, 21)
        XCTAssertEqual(Set(rows.map(\.name)), M3MCPSecurityPolicy.knownToolNames)
        XCTAssertEqual(rows.map(\.endpointPath), rows.map { "/tools/\($0.name)" })

        let permissionRequest = rows.first { $0.tool == .permissionsRequest }
        XCTAssertEqual(permissionRequest?.isEnabled, false)
        XCTAssertEqual(
            permissionRequest?.requiredEnvironmentVariable,
            M3MCPSecurityPolicy.permissionUIEnvironmentVariable
        )
        XCTAssertEqual(permissionRequest?.requiresOptIn, true)
        XCTAssertFalse(policy.allowsPermissionUI)
    }

    func testToolAvailabilityReflectsEnabledOptInsWithoutChangingVocabulary() {
        let policy = M3MCPSecurityPolicy(
            configuration: .init(allowPermissionUI: true, allowUserShortcuts: true)
        )
        let rows = policy.toolAvailability

        XCTAssertEqual(rows.count, M3MCPToolName.allCases.count)
        XCTAssertTrue(rows.first { $0.tool == .permissionsRequest }?.isEnabled == true)
        XCTAssertTrue(rows.first { $0.tool == .permissionsOpenSettings }?.isEnabled == true)
        XCTAssertTrue(rows.first { $0.tool == .aiTranslate }?.isEnabled == true)
        XCTAssertTrue(rows.first { $0.tool == .calendarCreateEvent }?.isEnabled == false)
        XCTAssertTrue(policy.allowsPermissionUI)
    }

    func testEachOptInEnablesOnlyItsOwnToolClass() {
        let calendar = M3MCPSecurityPolicy(
            configuration: .init(allowCalendarMutations: true)
        )
        XCTAssertTrue(calendar.allows(.calendarCreateEvent))
        XCTAssertTrue(calendar.allows(.calendarDeleteCalendar))
        // Undo is a write of its own, so it is behind the same launch opt-in as the writes it
        // reverses. Reaching for it does not become possible by having caused the mistake.
        XCTAssertTrue(calendar.allows(.calendarUndoWrite))
        XCTAssertFalse(calendar.allows(.permissionsRequest))
        XCTAssertFalse(calendar.allows(.aiTranslate))

        let permissionUI = M3MCPSecurityPolicy(
            configuration: .init(allowPermissionUI: true)
        )
        XCTAssertTrue(permissionUI.allows(.permissionsRequest))
        XCTAssertTrue(permissionUI.allows(.permissionsOpenSettings))
        XCTAssertFalse(permissionUI.allows(.calendarUpdateEvent))
        XCTAssertFalse(permissionUI.allows(.aiWritingTools))

        let shortcuts = M3MCPSecurityPolicy(
            configuration: .init(allowUserShortcuts: true)
        )
        XCTAssertTrue(shortcuts.allows(.aiWritingTools))
        XCTAssertTrue(shortcuts.allows(.aiTranslate))
        XCTAssertFalse(shortcuts.allows(.calendarDeleteEvent))
        XCTAssertFalse(shortcuts.allows(.permissionsOpenSettings))
    }

    func testAllExplicitOptInsEnableEveryKnownTool() {
        let policy = M3MCPSecurityPolicy(
            configuration: .init(
                allowCalendarMutations: true,
                allowPermissionUI: true,
                allowUserShortcuts: true
            )
        )

        XCTAssertEqual(M3MCPToolName.allCases.filter(policy.allows).count, 31)
    }

    func testEnvironmentResolutionIsInjectableAndFailsClosed() {
        let empty = M3MCPSecurityPolicy.fromEnvironment([:])
        XCTAssertEqual(empty.configuration, .defaultSafe)

        let enabled = M3MCPSecurityPolicy.fromEnvironment([
            M3MCPSecurityPolicy.calendarMutationsEnvironmentVariable: " true ",
            M3MCPSecurityPolicy.permissionUIEnvironmentVariable: "YES",
            M3MCPSecurityPolicy.userShortcutsEnvironmentVariable: "1"
        ])
        XCTAssertTrue(enabled.configuration.allowCalendarMutations)
        XCTAssertTrue(enabled.configuration.allowPermissionUI)
        XCTAssertTrue(enabled.configuration.allowUserShortcuts)

        let malformed = M3MCPSecurityPolicy.fromEnvironment([
            M3MCPSecurityPolicy.calendarMutationsEnvironmentVariable: "2",
            M3MCPSecurityPolicy.permissionUIEnvironmentVariable: "enabled",
            M3MCPSecurityPolicy.userShortcutsEnvironmentVariable: "false"
        ])
        XCTAssertEqual(malformed.configuration, .defaultSafe)
    }

    func testDeniedClassesDeclareTheRequiredLaunchOptIn() {
        XCTAssertEqual(
            M3MCPSecurityPolicy.requiredEnvironmentVariable(for: .calendarCreateEvent),
            M3MCPSecurityPolicy.calendarMutationsEnvironmentVariable
        )
        XCTAssertEqual(
            M3MCPSecurityPolicy.requiredEnvironmentVariable(for: .permissionsRequest),
            M3MCPSecurityPolicy.permissionUIEnvironmentVariable
        )
        XCTAssertEqual(
            M3MCPSecurityPolicy.requiredEnvironmentVariable(for: .aiTranslate),
            M3MCPSecurityPolicy.userShortcutsEnvironmentVariable
        )
        XCTAssertNil(M3MCPSecurityPolicy.requiredEnvironmentVariable(for: .calendarSearch))
        XCTAssertNil(M3MCPSecurityPolicy.requiredEnvironmentVariable(for: .aiSummarize))
        XCTAssertNil(M3MCPSecurityPolicy.requiredEnvironmentVariable(for: .aiImagePlayground))
    }
}
