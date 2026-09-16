import Foundation
import XCTest
@testable import M3MCPApp

final class SandboxStoreAccessTests: XCTestCase {
    func testMissingGrantsNeverFallBackToPersonalFolders() throws {
        let suite = "LocalMCP.StoreAccessTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let access = SandboxStoreAccess(preferences: preferences)
        for store in SandboxStoreAccess.Store.allCases {
            XCTAssertThrowsError(try access.url(for: store)) { error in
                XCTAssertTrue(error is SandboxStoreAccess.AccessError)
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testCorruptPersistedBookmarksFailClosedAcrossRestorationAttempts() throws {
        let suite = "LocalMCP.StoreAccessTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let corrupt = Data("invalid bookmark, no filesystem grant".utf8)
        for store in SandboxStoreAccess.Store.allCases {
            preferences.set(corrupt, forKey: "localmcp.sandbox.store.\(store.rawValue).bookmark")
        }
        // Recreating the access object models a new process restoring the same persisted data.
        for _ in 0..<2 {
            let access = SandboxStoreAccess(preferences: preferences)
            access.restore()
            for store in SandboxStoreAccess.Store.allCases {
                XCTAssertThrowsError(try access.url(for: store))
                XCTAssertEqual(preferences.data(forKey: "localmcp.sandbox.store.\(store.rawValue).bookmark"), corrupt)
            }
        }
    }
}
