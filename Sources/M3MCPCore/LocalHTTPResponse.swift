import Foundation

public struct LocalHTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum LocalHTTPResponseParser {
    public static let maximumHeaderBytes = 64 * 1_024
    /// Large local responses are still an untrusted resource-consumption surface. Eight MiB is
    /// enough for the bounded base64-audio result plus its JSON envelope, without allowing one
    /// provider call to amplify into tens of megabytes in the bridge.
    public static let maximumBodyBytes = 8 * 1_024 * 1_024
    public static let maximumWireBytes = maximumHeaderBytes + 4 + maximumBodyBytes

    public enum ParseError: Error, Equatable, Sendable {
        case incomplete
        case headerTooLarge
        case invalidUTF8
        case invalidStatusLine
        case invalidHeader
        case ambiguousFraming
        case invalidContentLength
        case bodyTooLarge
        case bodyLengthMismatch
    }

    /// Parses a response as soon as its declared body is complete. `nil` means that the bytes seen
    /// so far are still a valid prefix. Header and `Content-Length` violations are rejected before
    /// EOF so a peer cannot keep an obviously-invalid response open until the transport deadline.
    public static func parseIfComplete(_ data: Data) throws -> LocalHTTPResponse? {
        guard let header = try parseHeader(data) else { return nil }
        let expectedWireBytes = header.bodyStart + header.contentLength
        guard data.count <= expectedWireBytes else { throw ParseError.bodyLengthMismatch }
        guard data.count == expectedWireBytes else { return nil }

        return LocalHTTPResponse(
            status: header.status,
            body: Data(data[header.bodyStart..<expectedWireBytes])
        )
    }

    public static func parse(_ data: Data) throws -> LocalHTTPResponse {
        guard let header = try parseHeader(data) else {
            throw data.count > maximumHeaderBytes ? ParseError.headerTooLarge : ParseError.incomplete
        }
        let expectedWireBytes = header.bodyStart + header.contentLength
        guard data.count == expectedWireBytes else { throw ParseError.bodyLengthMismatch }
        return LocalHTTPResponse(
            status: header.status,
            body: Data(data[header.bodyStart..<expectedWireBytes])
        )
    }

    private struct ParsedHeader {
        let status: Int
        let bodyStart: Int
        let contentLength: Int
    }

    private static func parseHeader(_ data: Data) throws -> ParsedHeader? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            // A legal delimiter may begin at exactly maximumHeaderBytes, so retain at most its
            // three-byte partial suffix while streaming.
            guard data.count <= maximumHeaderBytes + 3 else {
                throw ParseError.headerTooLarge
            }
            return nil
        }
        guard separator.lowerBound <= maximumHeaderBytes else { throw ParseError.headerTooLarge }
        guard let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw ParseError.invalidUTF8
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw ParseError.invalidStatusLine }
        let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0] == "HTTP/1.1",
              statusParts[1].count == 3,
              let status = Int(statusParts[1]),
              (100...599).contains(status) else {
            throw ParseError.invalidStatusLine
        }

        var contentLength: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw ParseError.invalidHeader
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                throw ParseError.invalidHeader
            }
            if name == "transfer-encoding" {
                throw ParseError.ambiguousFraming
            }
            if name == "content-length" {
                guard contentLength == nil else { throw ParseError.ambiguousFraming }
                guard !value.isEmpty,
                      value.allSatisfy({ $0.isASCII && $0.isNumber }),
                      value == "0" || !value.hasPrefix("0"),
                      let parsed = Int(value) else {
                    throw ParseError.invalidContentLength
                }
                guard parsed <= maximumBodyBytes else { throw ParseError.bodyTooLarge }
                contentLength = parsed
            }
        }

        guard let contentLength else { throw ParseError.ambiguousFraming }
        return ParsedHeader(
            status: status,
            bodyStart: separator.upperBound,
            contentLength: contentLength
        )
    }
}
