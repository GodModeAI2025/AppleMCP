import Darwin
import Foundation

/// Transcript that Voice Memos stores inside a recording.
public struct VoiceMemoTranscript: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public let text: String
        public let start: Double
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public let text: String
    public let segments: [Segment]
    public let locale: String

    public init(text: String, segments: [Segment], locale: String) {
        self.text = text
        self.segments = segments
        self.locale = locale
    }
}

/// Reads the transcript that Voice Memos writes into the `.m4a` recording itself.
///
/// macOS keeps the transcript in a private MPEG-4 atom named `tsrp` below `moov/trak/udta`.
/// There is no sidecar file, so the recording has to be parsed. Atom headers are walked
/// lazily on a memory mapped file, which keeps large recordings cheap to inspect.
public enum VoiceMemoTranscriptReader {
    private static let maximumPayloadBytes = 8 * 1024 * 1024
    /// Limits applied before Foundation constructs an object graph for the private transcript JSON.
    /// These are deliberately well above normal Voice Memos payloads while preventing a small atom
    /// from expanding into an attacker-controlled number of Foundation collection objects.
    public static let maximumJSONDepth = 64
    public static let maximumJSONNodes = 262_144
    public static let maximumJSONContainers = 65_536
    public static let maximumRuns = 65_536
    public static let maximumAttributeEntries = 32_000
    public static let maximumSegments = 30_000
    public static let maximumTranscriptUTF8Bytes = 1_000_000
    public static let maximumLocaleUTF8Bytes = 128
    /// A valid Voice Memo uses only a small atom tree. This global walk budget keeps a dense
    /// attacker-controlled file from turning header discovery into millions of allocations or
    /// unbounded work before the transcript payload limit is reached.
    public static let maximumAtomsInspected = 65_536
    // A Voice Memo cannot plausibly span 100,000 hours. Capping display and parsed timeline values
    // keeps malformed metadata from reaching unsafe floating-point-to-Int conversions.
    private static let maximumTimelineSeconds = 359_999_999.0

    /// Returns the stored transcript, or `nil` when the recording carries none.
    public static func read(at url: URL) -> VoiceMemoTranscript? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        return read(fileDescriptor: descriptor)
    }

    /// Reads an already-open recording descriptor. Provider callers use this entry point after
    /// validating the descriptor's owner, type, link count, and expected inode.
    public static func read(fileDescriptor: Int32) -> VoiceMemoTranscript? {
        guard let payload = transcriptPayload(fileDescriptor: fileDescriptor) else {
            return nil
        }
        return parse(payload)
    }

    /// Reports whether the recording carries a usable transcript.
    ///
    /// macOS also writes a `tsrp` atom when recognition produced nothing, so the payload has to be
    /// decoded. Otherwise a search result would advertise a transcript that `read` cannot return.
    public static func hasTranscript(at url: URL) -> Bool {
        read(at: url) != nil
    }

    public static func hasTranscript(fileDescriptor: Int32) -> Bool {
        read(fileDescriptor: fileDescriptor) != nil
    }

    /// Renders a transcript as timestamped lines, grouped into readable chunks.
    public static func timestampedText(_ transcript: VoiceMemoTranscript, chunkSeconds: Double = 15) -> String {
        guard !transcript.segments.isEmpty else {
            return transcript.text
        }

        var lines: [String] = []
        var chunkStart = transcript.segments[0].start
        var chunkText = ""

        for segment in transcript.segments {
            chunkText += segment.text
            let spansEnoughTime = segment.end - chunkStart >= chunkSeconds
            let endsSentence = chunkText.hasSuffix(".") || chunkText.hasSuffix("!") || chunkText.hasSuffix("?")

            if spansEnoughTime || endsSentence {
                let trimmed = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append("[\(timecode(chunkStart))] \(trimmed)")
                }
                chunkText = ""
                chunkStart = segment.end
            }
        }

        let trailing = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            lines.append("[\(timecode(chunkStart))] \(trailing)")
        }

        return lines.joined(separator: "\n")
    }

    /// Formats seconds as `m:ss` or `h:mm:ss`.
    public static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let bounded = min(max(0, seconds), maximumTimelineSeconds)
        let total = Int(bounded.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Atom walking

    private struct Atom {
        let type: String
        let payload: Range<Int>
    }

    private struct AtomWalkBudget {
        var remaining = maximumAtomsInspected

        mutating func consume() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    private static func transcriptPayload(fileDescriptor: Int32) -> Data? {
        guard let data = mappedData(fileDescriptor: fileDescriptor) else {
            return nil
        }

        let fileRange = data.startIndex..<data.endIndex
        var budget = AtomWalkBudget()
        guard let moov = firstAtom("moov", in: data, range: fileRange, budget: &budget) else {
            return nil
        }

        var trackOffset = moov.payload.lowerBound
        while let track = nextAtom(
            in: data,
            range: moov.payload,
            offset: &trackOffset,
            budget: &budget
        ) {
            if track.type == "trak",
               let transcript = nestedAtom(
                   path: ["udta", "tsrp"],
                   in: data,
                   range: track.payload,
                   budget: &budget
               ) {
                return jsonPayload(data, range: transcript.payload)
            }
        }

        if let transcript = nestedAtom(
            path: ["udta", "tsrp"],
            in: data,
            range: moov.payload,
            budget: &budget
        ) {
            return jsonPayload(data, range: transcript.payload)
        }

        return nil
    }

    private static func mappedData(fileDescriptor: Int32) -> Data? {
        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0,
              let byteCount = Int(exactly: metadata.st_size) else {
            return nil
        }

        let address = mmap(
            nil,
            byteCount,
            PROT_READ,
            MAP_PRIVATE,
            fileDescriptor,
            0
        )
        guard address != MAP_FAILED, let address else { return nil }
        return Data(
            bytesNoCopy: address,
            count: byteCount,
            deallocator: .custom { mappedAddress, mappedByteCount in
                _ = munmap(mappedAddress, mappedByteCount)
            }
        )
    }

    private static func jsonPayload(_ data: Data, range: Range<Int>) -> Data? {
        guard range.count > 0, range.count <= maximumPayloadBytes else {
            return nil
        }

        // The payload repeats the atom name before the JSON document on some macOS versions.
        guard let start = data[range].firstIndex(of: UInt8(ascii: "{")) else {
            return nil
        }

        return data[start..<range.upperBound]
    }

    private static func nestedAtom(
        path: [String],
        in data: Data,
        range: Range<Int>,
        budget: inout AtomWalkBudget
    ) -> Atom? {
        var current = range
        var found: Atom?

        for type in path {
            guard let next = firstAtom(type, in: data, range: current, budget: &budget) else {
                return nil
            }
            found = next
            current = next.payload
        }

        return found
    }

    private static func firstAtom(
        _ type: String,
        in data: Data,
        range: Range<Int>,
        budget: inout AtomWalkBudget
    ) -> Atom? {
        var offset = range.lowerBound
        while let atom = nextAtom(in: data, range: range, offset: &offset, budget: &budget) {
            if atom.type == type { return atom }
        }
        return nil
    }

    /// Parses at most one header and advances `offset`. No array of sibling atoms is ever built.
    private static func nextAtom(
        in data: Data,
        range: Range<Int>,
        offset: inout Int,
        budget: inout AtomWalkBudget
    ) -> Atom? {
        guard range.lowerBound >= data.startIndex,
              range.lowerBound <= range.upperBound,
              range.upperBound <= data.endIndex,
              offset >= range.lowerBound,
              budget.consume(),
              boundedEnd(start: offset, length: 8, limit: range.upperBound) != nil
        else {
            return nil
        }

        guard let rawSize = readUInt32(data, at: offset),
              let typeOffset = adding(offset, 4),
              let type = readType(data, at: typeOffset) else {
            return nil
        }

        var headerSize = 8
        var size = Int(rawSize)

        if rawSize == 1 {
            // 64 bit atom: the real size follows the type field.
            guard let largeSizeOffset = adding(offset, 8),
                  let large = readUInt64(data, at: largeSizeOffset),
                  large <= UInt64(Int.max) else {
                return nil
            }
            size = Int(large)
            headerSize = 16
        } else if rawSize == 0 {
            // Atom extends to the end of the enclosing range.
            size = range.upperBound - offset
        }

        guard size >= headerSize,
              let payloadStart = boundedEnd(start: offset, length: headerSize, limit: range.upperBound),
              let atomEnd = boundedEnd(start: offset, length: size, limit: range.upperBound) else {
            return nil
        }

        offset = atomEnd
        return Atom(type: type, payload: payloadStart..<atomEnd)
    }

    private static func readType(_ data: Data, at offset: Int) -> String? {
        guard offset >= data.startIndex,
              let end = boundedEnd(start: offset, length: 4, limit: data.endIndex) else {
            return nil
        }

        let bytes = [UInt8](data[offset..<end])
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return nil
        }

        return String(bytes: bytes, encoding: .ascii)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= data.startIndex,
              let end = boundedEnd(start: offset, length: 4, limit: data.endIndex) else {
            return nil
        }

        var value: UInt32 = 0
        for byte in data[offset..<end] {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= data.startIndex,
              let end = boundedEnd(start: offset, length: 8, limit: data.endIndex) else {
            return nil
        }

        var value: UInt64 = 0
        for byte in data[offset..<end] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    /// Returns `start + length` only when it is non-overflowing and stays within `limit`.
    private static func boundedEnd(start: Int, length: Int, limit: Int) -> Int? {
        guard start >= 0, length >= 0, start <= limit, length <= limit - start else {
            return nil
        }
        return start + length
    }

    // MARK: - Payload parsing

    /// The payload is an archived attributed string: `runs` alternates text with an index into
    /// `attributeTable`, and each attribute entry carries the time range of the preceding text.
    private static func parse(_ payload: Data) -> VoiceMemoTranscript? {
        guard jsonComplexityIsWithinLimits(payload),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }

        let attributed = root["attributedString"] as? [String: Any]
        let runs = attributed?["runs"] as? [Any] ?? []
        let rawAttributeTable = attributed?["attributeTable"] as? [Any] ?? []
        guard runs.count <= maximumRuns,
              rawAttributeTable.count <= maximumAttributeEntries else {
            return nil
        }
        let attributeTable = rawAttributeTable as? [[String: Any]] ?? []
        let requestedLocale =
            (root["locale"] as? [String: Any])?["identifier"] as? String ?? "unknown"
        let locale = requestedLocale.utf8.count <= maximumLocaleUTF8Bytes
            ? requestedLocale
            : "unknown"

        var textRuns: [String] = []
        textRuns.reserveCapacity(min(runs.count, maximumRuns))
        var transcriptBytes = 0
        var segments: [VoiceMemoTranscript.Segment] = []
        segments.reserveCapacity(min(attributeTable.count, maximumSegments))
        var segmentTextBytes = 0
        var pending = ""

        for entry in runs {
            if let run = entry as? String {
                let runBytes = run.utf8.count
                guard runBytes <= maximumTranscriptUTF8Bytes - transcriptBytes else {
                    return nil
                }
                transcriptBytes += runBytes
                textRuns.append(run)
                pending = run
                continue
            }

            guard let index = (entry as? NSNumber)?.intValue,
                  index >= 0,
                  index < attributeTable.count,
                  !pending.isEmpty
            else {
                pending = ""
                continue
            }

            if let range = attributeTable[index]["timeRange"] as? [Double], range.count >= 2 {
                // Some payloads store [start, end], others [start, duration].
                let start = range[0]
                let second = range[1]
                guard start.isFinite,
                      second.isFinite,
                      start >= 0,
                      second >= 0,
                      start <= maximumTimelineSeconds
                else {
                    pending = ""
                    continue
                }

                let end = second >= start ? second : start + second
                if end.isFinite, end >= start, end <= maximumTimelineSeconds {
                    let pendingBytes = pending.utf8.count
                    guard segments.count < maximumSegments,
                          pendingBytes <= maximumTranscriptUTF8Bytes - segmentTextBytes else {
                        return nil
                    }
                    segmentTextBytes += pendingBytes
                    segments.append(VoiceMemoTranscript.Segment(text: pending, start: start, end: end))
                }
            }

            pending = ""
        }

        let text = textRuns.joined()
        guard !text.isEmpty || !segments.isEmpty else {
            return nil
        }

        return VoiceMemoTranscript(text: text, segments: segments, locale: locale)
    }

    /// Performs a single byte-wise pass before `JSONSerialization`. Strings and escape sequences
    /// are tracked explicitly, so braces, brackets, commas, and primitive-looking bytes inside
    /// transcript text never consume the structural budgets. Foundation remains responsible for
    /// full JSON syntax validation after this inexpensive complexity gate.
    private static func jsonComplexityIsWithinLimits(_ payload: Data) -> Bool {
        var containers: [UInt8] = []
        containers.reserveCapacity(maximumJSONDepth)
        var nodeCount = 0
        var containerCount = 0
        var inString = false
        var escaped = false
        var inPrimitive = false

        func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        func isPrimitiveDelimiter(_ byte: UInt8) -> Bool {
            isWhitespace(byte)
                || byte == 0x2C // ,
                || byte == 0x3A // :
                || byte == 0x5D // ]
                || byte == 0x7D // }
        }

        for byte in payload {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C { // \
                    escaped = true
                } else if byte == 0x22 { // "
                    inString = false
                }
                continue
            }

            if inPrimitive {
                if !isPrimitiveDelimiter(byte) {
                    continue
                }
                inPrimitive = false
            }

            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x3A: // whitespace, comma, colon
                continue

            case 0x22: // string (keys are counted too, conservatively)
                guard nodeCount < maximumJSONNodes else { return false }
                nodeCount += 1
                inString = true

            case 0x7B, 0x5B: // { [
                guard nodeCount < maximumJSONNodes,
                      containerCount < maximumJSONContainers,
                      containers.count < maximumJSONDepth else {
                    return false
                }
                nodeCount += 1
                containerCount += 1
                containers.append(byte)

            case 0x7D: // }
                guard containers.popLast() == 0x7B else { return false }

            case 0x5D: // ]
                guard containers.popLast() == 0x5B else { return false }

            default: // number, true, false, or null; JSONSerialization validates spelling
                guard nodeCount < maximumJSONNodes else { return false }
                nodeCount += 1
                inPrimitive = true
            }
        }

        return !inString && !escaped && containers.isEmpty
    }
}
