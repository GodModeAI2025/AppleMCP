import XCTest

import M3MCPCore

final class InputValidationTests: XCTestCase {
    func testJSONIntegerConversionRejectsFractionalNonFiniteAndOutOfRangeNumbers() {
        XCTAssertEqual(JSONValue.number(42).intValue, 42)
        XCTAssertNil(JSONValue.number(1.5).intValue)
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertNil(JSONValue.number(.nan).intValue)
        XCTAssertNil(JSONValue.number(Double.greatestFiniteMagnitude).intValue)
    }

    func testAcceptsCanonicalPositiveDecimals() {
        XCTAssertTrue(M3InputValidation.isCanonicalPositiveDecimal("1"))
        XCTAssertTrue(M3InputValidation.isCanonicalPositiveDecimal("987654321"))
        XCTAssertTrue(M3InputValidation.isCanonicalPositiveDecimal(String(UInt64.max)))
    }

    func testRejectsNonCanonicalOrUnsafeIdentifiers() {
        for value in [
            "", "0", "00", "01", "+1", "-1", " 1", "1 ", "1.0", "1/../2",
            "../../etc/passwd", "18446744073709551616"
        ] {
            XCTAssertFalse(M3InputValidation.isCanonicalPositiveDecimal(value), value)
        }
    }

    func testSHA256DigestValidationIsPathSafeAndExact() {
        XCTAssertTrue(M3InputValidation.isSHA256HexDigest(String(repeating: "a", count: 64)))
        XCTAssertTrue(M3InputValidation.isSHA256HexDigest(String(repeating: "F", count: 64)))

        for value in [
            "", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
            String(repeating: "g", count: 64), "../../outside", String(repeating: "0", count: 63) + "/"
        ] {
            XCTAssertFalse(M3InputValidation.isSHA256HexDigest(value), value)
        }
    }

    func testBoundedUTF8PrefixPreservesScalarsAndKeepsWorstCaseJSONUnderTransportLimit() throws {
        let multibyte = "aä€🙂z"
        let bounded = M3InputValidation.boundedUTF8Prefix(multibyte, maximumBytes: 7)
        XCTAssertEqual(bounded.text, "aä€")
        XCTAssertTrue(bounded.truncated)
        XCTAssertLessThanOrEqual(bounded.text.utf8.count, 7)

        let hostile = String(repeating: "\u{0001}", count: 1_000_000)
        let transcript = M3InputValidation.boundedUTF8Prefix(hostile, maximumBytes: 750_000)
        let response = ToolResponse(
            ok: true,
            source: "fixture",
            items: [
                DataItem(
                    id: "1",
                    title: "Bounded transcript",
                    kind: "voice_memo_transcript",
                    source: "fixture",
                    preview: transcript.text,
                    metadata: ["content_truncated": String(transcript.truncated)]
                )
            ]
        )
        let encoded = try M3JSON.makeEncoder().encode(response)
        XCTAssertLessThan(encoded.count, LocalHTTPResponseParser.maximumBodyBytes)
    }
}
