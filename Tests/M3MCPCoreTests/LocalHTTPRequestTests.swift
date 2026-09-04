import Foundation
import XCTest

import M3MCPCore

final class LocalHTTPRequestTests: XCTestCase {
    private let parser = LocalHTTPRequestParser()

    func testParsesCompleteRequestAndNormalizesHeaders() throws {
        let body = Data(#"{"query":"hello"}"#.utf8)
        let result = parser.parse(
            request(
                headers: [
                    "Host: localhost",
                    "Content-Type: application/json; charset=utf-8",
                    "Content-Length: \(body.count)"
                ],
                body: body
            )
        )

        guard case .complete(let parsed) = result else {
            return XCTFail("Expected a complete request, got \(result)")
        }
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/tools/mail_search")
        XCTAssertEqual(parsed.body, body)
        XCTAssertEqual(parsed.headers["host"], "localhost")
        XCTAssertEqual(parsed.headers["content-type"], "application/json; charset=utf-8")
    }

    func testIncompleteHeaderIsDistinctFromMalformedInput() {
        XCTAssertEqual(parser.parse(Data("POST /tools/x HTTP/1.1\r\nHost: local".utf8)), .incomplete)
    }

    func testIncompleteBodyIsDistinctFromMalformedInput() {
        let data = request(headers: ["Content-Length: 5"], body: Data("1234".utf8))
        XCTAssertEqual(parser.parse(data), .incomplete)
    }

    func testRejectsNegativeContentLengthWithoutCrashing() {
        let data = request(headers: ["Content-Length: -1"])
        XCTAssertEqual(parser.parse(data), .malformed(.negativeContentLength))
    }

    func testRejectsContentLengthIntegerOverflowWithoutCrashing() {
        let data = request(headers: ["Content-Length: 18446744073709551615"])
        XCTAssertEqual(parser.parse(data), .malformed(.contentLengthOverflow))
    }

    func testRejectsArbitrarilyLongContentLengthWithoutCrashing() {
        let data = request(headers: ["Content-Length: \(String(repeating: "9", count: 4_096))"])
        XCTAssertEqual(parser.parse(data), .malformed(.contentLengthOverflow))
    }

    func testRejectsInvalidContentLengths() {
        for value in ["", "+1", "1.0", "1,1", "0x10", "12 bytes", "١"] {
            let data = request(headers: ["Content-Length: \(value)"])
            XCTAssertEqual(
                parser.parse(data),
                .malformed(.invalidContentLength),
                "Expected Content-Length \(value.debugDescription) to be invalid"
            )
        }
    }

    func testRejectsOversizedBodyBeforeWaitingForIt() {
        let oversizedLength = LocalHTTPRequestParser.Limits().maximumBodyBytes + 1
        let data = request(headers: ["Content-Length: \(oversizedLength)"])
        XCTAssertEqual(parser.parse(data), .tooLarge(.body))
    }

    func testAcceptsBodyAtExactOneMegabyteLimit() {
        let maximumBodyBytes = LocalHTTPRequestParser.Limits().maximumBodyBytes
        let body = Data(repeating: 0x61, count: maximumBodyBytes)
        let data = request(headers: ["Content-Length: \(maximumBodyBytes)"], body: body)

        guard case .complete(let parsed) = parser.parse(data) else {
            return XCTFail("Expected exact-limit body to be accepted")
        }
        XCTAssertEqual(parsed.body.count, maximumBodyBytes)
        XCTAssertEqual(parsed.body.first, 0x61)
        XCTAssertEqual(parsed.body.last, 0x61)
    }

    func testRejectsDuplicateIdenticalContentLength() {
        let data = request(headers: ["Content-Length: 0", "Content-Length: 0"])
        XCTAssertEqual(parser.parse(data), .malformed(.duplicateContentLength))
    }

    func testRejectsConflictingContentLength() {
        let data = request(headers: ["Content-Length: 0", "Content-Length: 1"])
        XCTAssertEqual(parser.parse(data), .malformed(.duplicateContentLength))
    }

    func testRejectsCaseInsensitiveContentLengthDuplicate() {
        let data = request(headers: ["Content-Length: 0", "content-length: 0"])
        XCTAssertEqual(parser.parse(data), .malformed(.duplicateContentLength))
    }

    func testRejectsDuplicateOtherHeaders() {
        let data = request(headers: ["Host: localhost", "host: localhost"])
        XCTAssertEqual(parser.parse(data), .malformed(.duplicateHeader("host")))
    }

    func testRejectsTransferEncodingToAvoidAmbiguousFraming() {
        let data = request(headers: ["Transfer-Encoding: chunked"])
        XCTAssertEqual(parser.parse(data), .malformed(.unsupportedTransferEncoding))
    }

    func testRejectsMalformedHeaderLineInsteadOfIgnoringIt() {
        let data = request(headers: ["Host localhost"])
        XCTAssertEqual(parser.parse(data), .malformed(.invalidHeader))
    }

    func testRejectsWhitespaceInHeaderName() {
        let data = request(headers: ["Content Length: 0"])
        XCTAssertEqual(parser.parse(data), .malformed(.invalidHeader))
    }

    func testRejectsInvalidUTF8Headers() {
        var data = Data("POST /tools/x HTTP/1.1\r\nX-Test: ".utf8)
        data.append(0xff)
        data.append(Data("\r\n\r\n".utf8))
        XCTAssertEqual(parser.parse(data), .malformed(.invalidHeaderEncoding))
    }

    func testRejectsUnsupportedOrAmbiguousRequestLines() {
        for line in [
            "POST /tools/x",
            "POST  /tools/x HTTP/1.1",
            "POST /tools/x HTTP/2",
            "POST tools/x HTTP/1.1",
            "POST /tools/x HTTP/1.1 extra"
        ] {
            let data = rawRequest(line: line)
            XCTAssertEqual(
                parser.parse(data),
                .malformed(.invalidRequestLine),
                "Expected \(line.debugDescription) to be invalid"
            )
        }
    }

    func testRejectsBytesBeyondDeclaredBody() {
        let data = request(headers: ["Content-Length: 2"], body: Data("123".utf8))
        XCTAssertEqual(parser.parse(data), .malformed(.unexpectedTrailingBytes))
    }

    func testRejectsUndeclaredBody() {
        let data = request(headers: [], body: Data("{}".utf8))
        XCTAssertEqual(parser.parse(data), .malformed(.unexpectedTrailingBytes))
    }

    func testCapsHeaderReadWithoutTerminator() {
        let parser = LocalHTTPRequestParser(
            limits: .init(maximumHeaderBytes: 64, maximumBodyBytes: 32)
        )
        XCTAssertEqual(parser.parse(Data(repeating: 0x41, count: 63)), .incomplete)
        XCTAssertEqual(parser.parse(Data(repeating: 0x41, count: 64)), .tooLarge(.headers))
    }

    func testAcceptsHeaderTerminatorAtExactHeaderLimit() {
        let data = rawRequest(line: "GET /health HTTP/1.1")
        let exactParser = LocalHTTPRequestParser(
            limits: .init(maximumHeaderBytes: data.count, maximumBodyBytes: 0)
        )
        let shortParser = LocalHTTPRequestParser(
            limits: .init(maximumHeaderBytes: data.count - 1, maximumBodyBytes: 0)
        )

        guard case .complete = exactParser.parse(data) else {
            return XCTFail("Expected exact-limit header to be accepted")
        }
        XCTAssertEqual(shortParser.parse(data), .tooLarge(.headers))
    }

    func testMaximumBufferedBytesSaturatesOnOverflow() {
        let limits = LocalHTTPRequestParser.Limits(
            maximumHeaderBytes: Int.max,
            maximumBodyBytes: Int.max
        )
        XCTAssertEqual(limits.maximumBufferedBytes, Int.max)
    }

    func testToolInputDecoderDistinguishesEmptyObjectFromMalformedJSON() {
        XCTAssertEqual(LocalToolInputDecoder.decode(Data("{}".utf8)), [:])
        XCTAssertNil(LocalToolInputDecoder.decode(Data("{".utf8)))
        XCTAssertNil(LocalToolInputDecoder.decode(Data("[]".utf8)))
        XCTAssertNil(LocalToolInputDecoder.decode(Data()))
    }

    func testToolInputDecoderPreservesValidValues() {
        XCTAssertEqual(
            LocalToolInputDecoder.decode(Data(#"{"limit":5,"query":"test","flag":true}"#.utf8)),
            ["limit": .number(5), "query": .string("test"), "flag": .bool(true)]
        )
    }

    // MARK: - Fixtures

    private func request(headers: [String], body: Data = Data()) -> Data {
        rawRequest(
            line: "POST /tools/mail_search HTTP/1.1",
            headers: headers,
            body: body
        )
    }

    private func rawRequest(
        line: String,
        headers: [String] = [],
        body: Data = Data()
    ) -> Data {
        var text = line + "\r\n"
        if !headers.isEmpty {
            text += headers.joined(separator: "\r\n") + "\r\n"
        }
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}
