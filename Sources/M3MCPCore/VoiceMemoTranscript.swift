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

    /// Returns the stored transcript, or `nil` when the recording carries none.
    public static func read(at url: URL) -> VoiceMemoTranscript? {
        guard let payload = transcriptPayload(at: url) else {
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
        let total = max(0, Int(seconds.rounded()))
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

    private static func transcriptPayload(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }

        let fileRange = data.startIndex..<data.endIndex
        guard let moov = atom("moov", in: data, range: fileRange) else {
            return nil
        }

        for track in atoms(in: data, range: moov.payload) where track.type == "trak" {
            if let transcript = nestedAtom(path: ["udta", "tsrp"], in: data, range: track.payload) {
                return jsonPayload(data, range: transcript.payload)
            }
        }

        if let transcript = nestedAtom(path: ["udta", "tsrp"], in: data, range: moov.payload) {
            return jsonPayload(data, range: transcript.payload)
        }

        return nil
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

    private static func nestedAtom(path: [String], in data: Data, range: Range<Int>) -> Atom? {
        var current = range
        var found: Atom?

        for type in path {
            guard let next = atom(type, in: data, range: current) else {
                return nil
            }
            found = next
            current = next.payload
        }

        return found
    }

    private static func atom(_ type: String, in data: Data, range: Range<Int>) -> Atom? {
        atoms(in: data, range: range).first { $0.type == type }
    }

    private static func atoms(in data: Data, range: Range<Int>) -> [Atom] {
        var result: [Atom] = []
        var offset = range.lowerBound

        while offset + 8 <= range.upperBound {
            guard let rawSize = readUInt32(data, at: offset) else {
                break
            }

            guard let type = readType(data, at: offset + 4) else {
                break
            }

            var headerSize = 8
            var size = Int(rawSize)

            if rawSize == 1 {
                // 64 bit atom: the real size follows the type field.
                guard let large = readUInt64(data, at: offset + 8), large <= UInt64(Int.max) else {
                    break
                }
                size = Int(large)
                headerSize = 16
            } else if rawSize == 0 {
                // Atom extends to the end of the enclosing range.
                size = range.upperBound - offset
            }

            guard size >= headerSize, offset + size <= range.upperBound else {
                break
            }

            result.append(Atom(type: type, payload: (offset + headerSize)..<(offset + size)))
            offset += size
        }

        return result
    }

    private static func readType(_ data: Data, at offset: Int) -> String? {
        guard offset + 4 <= data.endIndex else {
            return nil
        }

        let bytes = [UInt8](data[offset..<(offset + 4)])
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return nil
        }

        return String(bytes: bytes, encoding: .ascii)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= data.startIndex, offset + 4 <= data.endIndex else {
            return nil
        }

        var value: UInt32 = 0
        for byte in data[offset..<(offset + 4)] {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= data.startIndex, offset + 8 <= data.endIndex else {
            return nil
        }

        var value: UInt64 = 0
        for byte in data[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    // MARK: - Payload parsing

    /// The payload is an archived attributed string: `runs` alternates text with an index into
    /// `attributeTable`, and each attribute entry carries the time range of the preceding text.
    private static func parse(_ payload: Data) -> VoiceMemoTranscript? {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }

        let attributed = root["attributedString"] as? [String: Any]
        let runs = attributed?["runs"] as? [Any] ?? []
        let attributeTable = attributed?["attributeTable"] as? [[String: Any]] ?? []
        let locale = (root["locale"] as? [String: Any])?["identifier"] as? String ?? "unknown"

        var text = ""
        var segments: [VoiceMemoTranscript.Segment] = []
        var pending = ""

        for entry in runs {
            if let run = entry as? String {
                text += run
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
                let end = range[1] >= start ? range[1] : start + range[1]
                segments.append(VoiceMemoTranscript.Segment(text: pending, start: start, end: end))
            }

            pending = ""
        }

        guard !text.isEmpty || !segments.isEmpty else {
            return nil
        }

        return VoiceMemoTranscript(text: text, segments: segments, locale: locale)
    }
}
