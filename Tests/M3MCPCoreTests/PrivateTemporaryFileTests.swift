import Darwin
import Foundation
import XCTest
@testable import M3MCPCore

final class PrivateTemporaryFileTests: XCTestCase {
    func testCreatesOwnerOnlyFileWithExactContents() throws {
        let directory = FileManager.default.temporaryDirectory
        let payload = Data("private payload".utf8)
        let url = try PrivateTemporaryFile.write(
            payload,
            directory: directory,
            prefix: "m3mcp-private-test-",
            suffix: ".txt"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try Data(contentsOf: url), payload)
        var metadata = stat()
        XCTAssertEqual(url.path.withCString { lstat($0, &metadata) }, 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(metadata.st_uid, getuid())
    }
}
