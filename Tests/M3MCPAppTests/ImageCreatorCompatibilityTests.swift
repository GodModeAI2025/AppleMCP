import XCTest
@testable import M3MCPApp

final class ImageCreatorCompatibilityTests: XCTestCase {
    func testMacOS27ReturnsExplicitRemovalInsteadOfAttemptingGeneration() async throws {
        guard #available(macOS 27, *) else { throw XCTSkip("Only macOS 27 removed ImageCreator") }
        let response = await AppleIntelligenceProvider().imagePlayground(input: ["concept": .string("Synthetic red apple")])
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.items.isEmpty)
        XCTAssertEqual(response.meta?["reason"], "image_creator_removed")
        XCTAssertTrue(AppleIntelligenceProvider.imageCreationStatusDescription.contains("macOS 27"))
    }
}
