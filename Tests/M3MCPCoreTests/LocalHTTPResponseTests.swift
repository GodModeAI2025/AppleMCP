import Foundation
import XCTest
@testable import M3MCPCore

final class LocalHTTPResponseTests: XCTestCase {
    func testParsesExactBoundedResponse() throws {
        let body = Data("{\"ok\":true}".utf8)
        let wire = response(headers: ["Content-Length: \(body.count)"], body: body)
        let parsed = try LocalHTTPResponseParser.parse(wire)
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.body, body)
    }

    func testRejectsMissingDuplicateAndInvalidLengths() {
        assertError(.ambiguousFraming, response(headers: [], body: Data()))
        assertError(.ambiguousFraming, response(headers: ["Content-Length: 0", "content-length: 0"], body: Data()))
        assertError(.invalidContentLength, response(headers: ["Content-Length: -1"], body: Data()))
        assertError(.invalidContentLength, response(headers: ["Content-Length: 00"], body: Data()))
        assertError(.invalidContentLength, response(headers: ["Content-Length: 999999999999999999999"], body: Data()))
        assertError(.bodyTooLarge, response(headers: ["Content-Length: \(LocalHTTPResponseParser.maximumBodyBytes + 1)"], body: Data()))
    }

    func testRejectsAmbiguousOrMismatchedFraming() {
        assertError(.ambiguousFraming, response(headers: ["Content-Length: 0", "Transfer-Encoding: chunked"], body: Data()))
        assertError(.bodyLengthMismatch, response(headers: ["Content-Length: 4"], body: Data("abc".utf8)))
        assertError(.bodyLengthMismatch, response(headers: ["Content-Length: 2"], body: Data("abc".utf8)))
    }

    func testRejectsMalformedStatusAndHeaders() {
        assertError(.invalidStatusLine, Data("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        assertError(.invalidStatusLine, Data("HTTP/1.1 nope\r\nContent-Length: 0\r\n\r\n".utf8))
        assertError(.invalidHeader, Data("HTTP/1.1 200 OK\r\nBad Header: x\r\nContent-Length: 0\r\n\r\n".utf8))
    }

    func testStreamingParserWaitsForDeclaredBodyThenCompletesWithoutEOF() throws {
        let header = Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".utf8)
        XCTAssertNil(try LocalHTTPResponseParser.parseIfComplete(header))

        var partial = header
        partial.append(Data("abc".utf8))
        XCTAssertNil(try LocalHTTPResponseParser.parseIfComplete(partial))

        partial.append(Data("d".utf8))
        XCTAssertEqual(
            try LocalHTTPResponseParser.parseIfComplete(partial),
            LocalHTTPResponse(status: 200, body: Data("abcd".utf8))
        )
    }

    func testStreamingParserRejectsOversizedDeclarationBeforeBodyOrEOF() {
        let header = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: \(LocalHTTPResponseParser.maximumBodyBytes + 1)\r\n\r\n".utf8
        )
        XCTAssertThrowsError(try LocalHTTPResponseParser.parseIfComplete(header)) { error in
            XCTAssertEqual(error as? LocalHTTPResponseParser.ParseError, .bodyTooLarge)
        }
    }

    func testStreamingParserRejectsTrailingBytesAlreadyOnWire() {
        let data = response(headers: ["Content-Length: 2"], body: Data("abc".utf8))
        XCTAssertThrowsError(try LocalHTTPResponseParser.parseIfComplete(data)) { error in
            XCTAssertEqual(error as? LocalHTTPResponseParser.ParseError, .bodyLengthMismatch)
        }
    }

    private func response(headers: [String], body: Data) -> Data {
        var data = Data("HTTP/1.1 200 OK\r\n".utf8)
        for header in headers { data.append(Data("\(header)\r\n".utf8)) }
        data.append(Data("\r\n".utf8))
        data.append(body)
        return data
    }

    private func assertError(
        _ expected: LocalHTTPResponseParser.ParseError,
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try LocalHTTPResponseParser.parse(data), file: file, line: line) { error in
            XCTAssertEqual(error as? LocalHTTPResponseParser.ParseError, expected, file: file, line: line)
        }
    }
}
