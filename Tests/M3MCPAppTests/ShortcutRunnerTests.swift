import Foundation
import XCTest
@testable import M3MCPApp

final class ShortcutRunnerTests: XCTestCase {
    func testPlainTextDecoderRequiresValidUTF8AndTrimsWhitespace() {
        XCTAssertEqual(
            ShortcutRunner.decodeUTF8PlainText(Data("  Grüße\n".utf8)),
            "Grüße"
        )
        XCTAssertNil(ShortcutRunner.decodeUTF8PlainText(Data([0xC3, 0x28])))
    }

    func testProcessInvocationSendsExactJSONOnStdinWithoutAReopenablePath() {
        let payload = Data([0x00, 0x0A, 0x22, 0x5C, 0xFF])
        let invocation = ShortcutRunner.processInvocation(
            named: "Writing Tools",
            jsonInput: payload,
            timeout: 12.5
        )

        XCTAssertEqual(invocation.executableURL.path, "/usr/bin/shortcuts")
        XCTAssertEqual(
            invocation.arguments,
            [
                "run", "Writing Tools",
                "--input-path", "-",
                "--output-type", "public.utf8-plain-text"
            ]
        )
        XCTAssertEqual(invocation.standardInput, payload)
        XCTAssertEqual(invocation.timeout, 12.5)
        XCTAssertEqual(invocation.maximumOutputBytes, 1_048_576)
        XCTAssertFalse(invocation.arguments.contains { $0.contains("m3mcp-shortcut-input-") })
    }
    func testNativeOutputAcceptsOnlyBoundedNonemptyText() throws {
        XCTAssertEqual(try NativeShortcutRunner.decodeOutput("  Grüße\n").get(), "Grüße")
        XCTAssertThrowsError(try NativeShortcutRunner.decodeOutput(nil).get())
        XCTAssertThrowsError(try NativeShortcutRunner.decodeOutput(["text"]).get())
        XCTAssertThrowsError(try NativeShortcutRunner.decodeOutput("  \n").get())
        XCTAssertNoThrow(try NativeShortcutRunner.decodeOutput(String(repeating: "a", count: 1_048_576)).get())
        XCTAssertThrowsError(try NativeShortcutRunner.decodeOutput(String(repeating: "ä", count: 524_289)).get())
    }
}
