import Foundation

/// The deliberately small HTTP subset accepted by M3MCP's private Unix-socket transport.
///
/// This is not intended to be a general-purpose HTTP implementation. Keeping framing in the core
/// target makes every length and boundary decision independently testable without starting the app
/// or granting it macOS permissions.
public struct LocalHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let body: Data
    /// Header names are normalized to lowercase.
    public let headers: [String: String]

    public init(method: String, path: String, body: Data, headers: [String: String]) {
        self.method = method
        self.path = path
        self.body = body
        self.headers = headers
    }
}

public struct LocalHTTPRequestParser: Sendable {
    public struct Limits: Equatable, Sendable {
        /// Includes the terminating CRLF-CRLF sequence.
        public let maximumHeaderBytes: Int
        public let maximumBodyBytes: Int

        public init(
            maximumHeaderBytes: Int = 32 * 1_024,
            maximumBodyBytes: Int = M3MCPProtocolEngine.defaultMaximumMessageBytes
        ) {
            self.maximumHeaderBytes = max(0, maximumHeaderBytes)
            self.maximumBodyBytes = max(0, maximumBodyBytes)
        }

        /// Upper bound used by the socket reader. Saturation keeps even injected test limits safe.
        public var maximumBufferedBytes: Int {
            let (sum, overflow) = maximumHeaderBytes.addingReportingOverflow(maximumBodyBytes)
            return overflow ? Int.max : sum
        }
    }

    public enum MalformedReason: Equatable, Sendable {
        case invalidHeaderEncoding
        case invalidRequestLine
        case invalidHeader
        case duplicateHeader(String)
        case duplicateContentLength
        case invalidContentLength
        case negativeContentLength
        case contentLengthOverflow
        case unsupportedTransferEncoding
        case unexpectedTrailingBytes

        public var clientMessage: String {
            switch self {
            case .invalidHeaderEncoding:
                return "Request headers must be valid UTF-8."
            case .invalidRequestLine:
                return "Malformed HTTP request line."
            case .invalidHeader:
                return "Malformed HTTP header."
            case .duplicateHeader(let name):
                return "Duplicate HTTP header: \(name)."
            case .duplicateContentLength:
                return "Content-Length must be supplied at most once."
            case .invalidContentLength:
                return "Content-Length must contain decimal digits only."
            case .negativeContentLength:
                return "Content-Length cannot be negative."
            case .contentLengthOverflow:
                return "Content-Length is outside the supported integer range."
            case .unsupportedTransferEncoding:
                return "Transfer-Encoding is not supported on the local endpoint."
            case .unexpectedTrailingBytes:
                return "Request contains bytes beyond its declared body."
            }
        }
    }

    public enum TooLargeReason: Equatable, Sendable {
        case headers
        case body
    }

    public enum Result: Equatable, Sendable {
        case incomplete
        case malformed(MalformedReason)
        case tooLarge(TooLargeReason)
        case complete(LocalHTTPRequest)
    }

    public let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func parse(_ data: Data) -> Result {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerEnd = data.range(of: delimiter) else {
            // A complete delimiter at exactly the limit is accepted because the lookup happens
            // first. With this many bytes and no delimiter, no legal header can still be formed.
            return data.count >= limits.maximumHeaderBytes ? .tooLarge(.headers) : .incomplete
        }

        let headerByteCount = data.distance(from: data.startIndex, to: headerEnd.upperBound)
        guard headerByteCount <= limits.maximumHeaderBytes else {
            return .tooLarge(.headers)
        }

        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed(.invalidHeaderEncoding)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              let requestParts = parseRequestLine(requestLine)
        else {
            return .malformed(.invalidRequestLine)
        }

        var headers: [String: String] = [:]
        var contentLengthText: String?

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .malformed(.invalidHeader)
            }

            let name = String(line[..<colon])
            let valueStart = line.index(after: colon)
            let value = String(line[valueStart...]).trimmingCharacters(in: Self.optionalWhitespace)
            guard isValidHeaderName(name), isValidHeaderValue(value) else {
                return .malformed(.invalidHeader)
            }

            let normalizedName = name.lowercased()
            if normalizedName == "content-length" {
                guard contentLengthText == nil else {
                    return .malformed(.duplicateContentLength)
                }
                contentLengthText = value
            } else if normalizedName == "transfer-encoding" {
                return .malformed(.unsupportedTransferEncoding)
            }

            guard headers[normalizedName] == nil else {
                return .malformed(.duplicateHeader(normalizedName))
            }
            headers[normalizedName] = value
        }

        let contentLength: Int
        if let contentLengthText {
            switch parseContentLength(contentLengthText) {
            case .value(let value):
                contentLength = value
            case .malformed(let reason):
                return .malformed(reason)
            }
        } else {
            contentLength = 0
        }

        guard contentLength <= limits.maximumBodyBytes else {
            return .tooLarge(.body)
        }

        let availableBodyBytes = data.distance(from: headerEnd.upperBound, to: data.endIndex)
        guard availableBodyBytes >= contentLength else {
            return .incomplete
        }
        guard availableBodyBytes == contentLength else {
            return .malformed(.unexpectedTrailingBytes)
        }

        guard let bodyEnd = data.index(
            headerEnd.upperBound,
            offsetBy: contentLength,
            limitedBy: data.endIndex
        ) else {
            // The distance checks above make this unreachable, but retaining the checked index
            // keeps the range construction safe if the implementation changes later.
            return .incomplete
        }

        return .complete(
            LocalHTTPRequest(
                method: requestParts.method,
                path: requestParts.path,
                body: Data(data[headerEnd.upperBound..<bodyEnd]),
                headers: headers
            )
        )
    }

    private static let optionalWhitespace = CharacterSet(charactersIn: " \t")

    private func parseRequestLine(_ line: String) -> (method: String, path: String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else {
            return nil
        }

        let method = String(parts[0])
        let path = String(parts[1])
        guard isValidToken(method), path.first == "/", !containsControlOrWhitespace(path) else {
            return nil
        }
        return (method, path)
    }

    private func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && isValidToken(name)
    }

    private func isValidToken(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122:
                return true
            case 33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
                return true
            default:
                return false
            }
        }
    }

    private func isValidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 9 || scalar.value >= 32 && scalar.value != 127
        }
    }

    private func containsControlOrWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value <= 32 || scalar.value == 127
        }
    }

    private enum ContentLengthResult {
        case value(Int)
        case malformed(MalformedReason)
    }

    private func parseContentLength(_ text: String) -> ContentLengthResult {
        guard !text.isEmpty else {
            return .malformed(.invalidContentLength)
        }

        let textBytes = Array(text.utf8)
        if textBytes.first == 45,
           textBytes.count > 1,
           textBytes.dropFirst().allSatisfy({ (48...57).contains($0) }) {
            return .malformed(.negativeContentLength)
        }

        guard textBytes.allSatisfy({ (48...57).contains($0) }) else {
            return .malformed(.invalidContentLength)
        }

        var value = 0
        for byte in textBytes {
            let digit = Int(byte - 48)
            let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
            guard !multiplyOverflow else {
                return .malformed(.contentLengthOverflow)
            }
            let (next, addOverflow) = multiplied.addingReportingOverflow(digit)
            guard !addOverflow else {
                return .malformed(.contentLengthOverflow)
            }
            value = next
        }
        return .value(value)
    }
}

/// Decodes the only JSON shape accepted by `/tools/*` while preserving the distinction between a
/// valid empty object and malformed input. Callers must handle `nil` as a client error rather than
/// silently replacing it with `[:]`.
public enum LocalToolInputDecoder {
    public static func decode(_ data: Data) -> [String: JSONValue]? {
        try? M3JSON.makeDecoder().decode([String: JSONValue].self, from: data)
    }
}
