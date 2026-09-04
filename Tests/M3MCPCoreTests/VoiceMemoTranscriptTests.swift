import Foundation
import XCTest

import M3MCPCore

/// Fixtures are built in code so the repository carries no binary recordings.
/// Expected values were cross-checked against the upstream TypeScript parser of
/// jwulff/apple-voice-memo-mcp on byte-identical inputs.
final class VoiceMemoTranscriptTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VoiceMemoTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testReadsTranscriptFromRecording() throws {
        let url = try write(name: "plain.m4a", contents: recording(payload: Data(sampleJSON.utf8)))
        let transcript = try XCTUnwrap(VoiceMemoTranscriptReader.read(at: url))

        XCTAssertEqual(transcript.text, "Hallo das ist ein Test. Ende.")
        XCTAssertEqual(transcript.locale, "de-DE")
        XCTAssertEqual(transcript.segments, [
            VoiceMemoTranscript.Segment(text: "Hallo ", start: 0, end: 1.5),
            VoiceMemoTranscript.Segment(text: "das ist ein Test. ", start: 1.5, end: 4.25),
            VoiceMemoTranscript.Segment(text: "Ende.", start: 4.25, end: 5)
        ])
        XCTAssertTrue(VoiceMemoTranscriptReader.hasTranscript(at: url))
    }

    /// Some macOS versions repeat the atom name before the JSON document.
    func testSkipsAtomNamePrefixBeforeJSON() throws {
        let payload = Data("tsrp".utf8) + Data(sampleJSON.utf8)
        let url = try write(name: "prefixed.m4a", contents: recording(payload: payload))

        XCTAssertEqual(VoiceMemoTranscriptReader.read(at: url)?.text, "Hallo das ist ein Test. Ende.")
    }

    /// The transcript does not have to live in the first track.
    func testFindsTranscriptInLaterTrack() throws {
        let url = try write(
            name: "second-track.m4a",
            contents: recording(payload: Data(sampleJSON.utf8), tracks: 3, transcriptTrack: 1)
        )

        XCTAssertEqual(VoiceMemoTranscriptReader.read(at: url)?.segments.count, 3)
    }

    /// Long recordings use 64 bit atom sizes.
    func testReadsSixtyFourBitAtoms() throws {
        let url = try write(
            name: "wide.m4a",
            contents: recording(payload: Data(sampleJSON.utf8), wideTranscriptAtom: true)
        )

        XCTAssertEqual(VoiceMemoTranscriptReader.read(at: url)?.locale, "de-DE")
    }

    func testRejectsSixtyFourBitAtomLargerThanInt() throws {
        var malformed = atom("ftyp", Data("M4A ".utf8))
        malformed.append(wideAtomHeader("moov", declaredSize: UInt64.max))
        let url = try write(name: "oversized-wide-atom.m4a", contents: malformed)

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
    }

    /// A representable atom size can still overflow when added to a nonzero file offset.
    func testRejectsAtomWhoseOffsetPlusSizeWouldOverflow() throws {
        var malformed = atom("ftyp", Data("M4A ".utf8))
        malformed.append(wideAtomHeader("moov", declaredSize: UInt64(Int.max)))
        let url = try write(name: "offset-overflow-atom.m4a", contents: malformed)

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
    }

    func testReturnsNilWithoutTranscriptAtom() throws {
        let url = try write(name: "silent.m4a", contents: recording(payload: nil))

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
        XCTAssertFalse(VoiceMemoTranscriptReader.hasTranscript(at: url))
    }

    func testDenseAtomFileStopsAtGlobalWorkBudgetWithoutBuildingSiblingArray() throws {
        let emptyAtom = atom("free", Data())
        var densePayload = Data()
        densePayload.reserveCapacity(
            emptyAtom.count * (VoiceMemoTranscriptReader.maximumAtomsInspected + 1)
        )
        for _ in 0...VoiceMemoTranscriptReader.maximumAtomsInspected {
            densePayload.append(emptyAtom)
        }
        // A valid transcript after the budget must not be reached by unbounded scanning.
        densePayload.append(
            atom("trak", atom("udta", atom("tsrp", Data(sampleJSON.utf8))))
        )
        var file = atom("ftyp", Data("M4A ".utf8))
        file.append(atom("moov", densePayload))
        let url = try write(name: "dense-atoms.m4a", contents: file)

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
    }

    /// An atom that decodes to no text must not be advertised as a transcript.
    func testTreatsEmptyTranscriptAsMissing() throws {
        let json = #"{"attributedString":{"runs":[],"attributeTable":[]},"locale":{"identifier":"en-US"}}"#
        let url = try write(name: "empty.m4a", contents: recording(payload: Data(json.utf8)))

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
        XCTAssertFalse(VoiceMemoTranscriptReader.hasTranscript(at: url))
    }

    /// A run without a following attribute index carries no time range.
    func testKeepsTextOfRunsWithoutTimeRange() throws {
        let json = """
        {"attributedString":{"runs":["nur text ohne index","zweiter lauf ",0],\
        "attributeTable":[{"timeRange":[1.0,2.0]}]},"locale":{"identifier":"fr-FR"}}
        """
        let url = try write(name: "partial.m4a", contents: recording(payload: Data(json.utf8)))
        let transcript = try XCTUnwrap(VoiceMemoTranscriptReader.read(at: url))

        XCTAssertEqual(transcript.text, "nur text ohne indexzweiter lauf ")
        XCTAssertEqual(transcript.segments, [
            VoiceMemoTranscript.Segment(text: "zweiter lauf ", start: 1, end: 2)
        ])
    }

    /// Payloads that store [start, duration] must not produce an end before the start.
    func testNormalizesDurationStyleTimeRanges() throws {
        let json = """
        {"attributedString":{"runs":["Erst ",0,"zweit",1],\
        "attributeTable":[{"timeRange":[0.0,2.0]},{"timeRange":[2.0,1.5]}]},\
        "locale":{"identifier":"de-DE"}}
        """
        let url = try write(name: "durations.m4a", contents: recording(payload: Data(json.utf8)))
        let transcript = try XCTUnwrap(VoiceMemoTranscriptReader.read(at: url))

        XCTAssertEqual(transcript.segments.last, VoiceMemoTranscript.Segment(text: "zweit", start: 2, end: 3.5))
    }

    func testDropsExtremeTimelineValuesWithoutDroppingText() throws {
        let json = """
        {"attributedString":{"runs":["Untrusted time",0],\
        "attributeTable":[{"timeRange":[1e308,1e308]}]},\
        "locale":{"identifier":"de-DE"}}
        """
        let url = try write(name: "extreme-time.m4a", contents: recording(payload: Data(json.utf8)))
        let transcript = try XCTUnwrap(VoiceMemoTranscriptReader.read(at: url))

        XCTAssertEqual(transcript.text, "Untrusted time")
        XCTAssertTrue(transcript.segments.isEmpty)
    }

    func testStructuralPreflightIgnoresJSONDelimitersAndEscapesInsideTranscriptStrings() throws {
        let expected = #"Text { [ ] } , : with an escaped quote \" and slash \\ stays data."#
        let payload = try JSONSerialization.data(withJSONObject: [
            "attributedString": [
                "runs": [expected, 0],
                "attributeTable": [["timeRange": [0.0, 1.0]]]
            ],
            "locale": ["identifier": "de-DE"]
        ])
        let url = try write(name: "string-delimiters.m4a", contents: recording(payload: payload))

        XCTAssertEqual(VoiceMemoTranscriptReader.read(at: url)?.text, expected)
    }

    func testRejectsJSONBeyondStructuralDepthLimitBeforeFoundationDecoding() throws {
        let nesting = VoiceMemoTranscriptReader.maximumJSONDepth + 1
        let json = #"{"junk":"#
            + String(repeating: "[", count: nesting)
            + "0"
            + String(repeating: "]", count: nesting)
            + #", "attributedString":{"runs":["text"],"attributeTable":[]}}"#
        let url = try write(name: "deep-json.m4a", contents: recording(payload: Data(json.utf8)))

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
    }

    func testRejectsJSONBeyondContainerLimitBeforeFoundationDecoding() throws {
        let containers = Array(
            repeating: "[]",
            count: VoiceMemoTranscriptReader.maximumJSONContainers + 1
        ).joined(separator: ",")
        let json = #"{"junk":["# + containers + #"],"attributedString":{"runs":["text"],"attributeTable":[]}}"#
        let url = try write(name: "many-containers.m4a", contents: recording(payload: Data(json.utf8)))

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
    }

    func testRejectsJSONBeyondNodeLimitBeforeFoundationDecoding() throws {
        let nodes = Array(
            repeating: "0",
            count: VoiceMemoTranscriptReader.maximumJSONNodes + 1
        ).joined(separator: ",")
        let json = #"{"junk":["# + nodes + #"],"attributedString":{"runs":["text"],"attributeTable":[]}}"#
        let url = try write(name: "many-nodes.m4a", contents: recording(payload: Data(json.utf8)))

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
    }

    func testRejectsExcessiveRunAndAttributeCounts() throws {
        let excessiveRuns = Array(
            repeating: "0",
            count: VoiceMemoTranscriptReader.maximumRuns + 1
        ).joined(separator: ",")
        let runsJSON = #"{"attributedString":{"runs":["# + excessiveRuns + #"],"attributeTable":[]}}"#
        let runsURL = try write(
            name: "many-runs.m4a",
            contents: recording(payload: Data(runsJSON.utf8))
        )

        let excessiveAttributes = Array(
            repeating: "{}",
            count: VoiceMemoTranscriptReader.maximumAttributeEntries + 1
        ).joined(separator: ",")
        let attributesJSON = #"{"attributedString":{"runs":["text"],"attributeTable":["#
            + excessiveAttributes + "]}}"
        let attributesURL = try write(
            name: "many-attributes.m4a",
            contents: recording(payload: Data(attributesJSON.utf8))
        )

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: runsURL))
        XCTAssertNil(VoiceMemoTranscriptReader.read(at: attributesURL))
    }

    func testRejectsTranscriptTextBeyondCumulativeUTF8Limit() throws {
        let text = String(
            repeating: "x",
            count: VoiceMemoTranscriptReader.maximumTranscriptUTF8Bytes + 1
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "attributedString": ["runs": [text], "attributeTable": []]
        ])
        let url = try write(name: "oversized-text.m4a", contents: recording(payload: payload))

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
    }

    func testRejectsExcessiveDecodedSegmentCount() throws {
        let count = VoiceMemoTranscriptReader.maximumSegments + 1
        let runs = Array(repeating: #""x",0"#, count: count).joined(separator: ",")
        let attributes = Array(
            repeating: #"{"timeRange":[0,1]}"#,
            count: count
        ).joined(separator: ",")
        let json = #"{"attributedString":{"runs":["# + runs
            + #"],"attributeTable":["# + attributes + "]}}"
        let url = try write(name: "many-segments.m4a", contents: recording(payload: Data(json.utf8)))

        XCTAssertNil(VoiceMemoTranscriptReader.read(at: url))
    }

    func testOversizedLocaleFallsBackToBoundedUnknownValue() throws {
        let locale = String(
            repeating: "x",
            count: VoiceMemoTranscriptReader.maximumLocaleUTF8Bytes + 1
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "attributedString": ["runs": ["text"], "attributeTable": []],
            "locale": ["identifier": locale]
        ])
        let url = try write(name: "oversized-locale.m4a", contents: recording(payload: payload))

        XCTAssertEqual(VoiceMemoTranscriptReader.read(at: url)?.locale, "unknown")
    }

    func testRendersTimestampedLines() {
        let transcript = VoiceMemoTranscript(
            text: "Erster Satz. Zweiter Satz.",
            segments: [
                VoiceMemoTranscript.Segment(text: "Erster Satz.", start: 0, end: 4),
                VoiceMemoTranscript.Segment(text: " Zweiter Satz.", start: 4, end: 65)
            ],
            locale: "de-DE"
        )

        XCTAssertEqual(
            VoiceMemoTranscriptReader.timestampedText(transcript),
            "[0:00] Erster Satz.\n[0:04] Zweiter Satz."
        )
    }

    func testFormatsTimecodes() {
        XCTAssertEqual(VoiceMemoTranscriptReader.timecode(0), "0:00")
        XCTAssertEqual(VoiceMemoTranscriptReader.timecode(65.4), "1:05")
        XCTAssertEqual(VoiceMemoTranscriptReader.timecode(3_725), "1:02:05")
        XCTAssertEqual(VoiceMemoTranscriptReader.timecode(-3), "0:00")
    }

    func testTimecodesRejectNonFiniteAndClampHugeFiniteValues() {
        XCTAssertEqual(VoiceMemoTranscriptReader.timecode(.nan), "0:00")
        XCTAssertEqual(VoiceMemoTranscriptReader.timecode(.infinity), "0:00")
        XCTAssertEqual(VoiceMemoTranscriptReader.timecode(-.infinity), "0:00")
        XCTAssertEqual(VoiceMemoTranscriptReader.timecode(.greatestFiniteMagnitude), "99999:59:59")
    }

    // MARK: - Fixtures

    private let sampleJSON = """
    {"attributedString":{"runs":["Hallo ",0,"das ist ein Test. ",1,"Ende.",2],\
    "attributeTable":[{"timeRange":[0.0,1.5]},{"timeRange":[1.5,4.25]},{"timeRange":[4.25,5.0]}]},\
    "locale":{"identifier":"de-DE","current":1}}
    """

    private func write(name: String, contents: Data) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url)
        return url
    }

    private func atom(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: bigEndian(UInt32(payload.count + 8)))
        data.append(contentsOf: Array(type.utf8))
        data.append(payload)
        return data
    }

    /// Atom with `size == 1`, where the real size follows the type field as a 64 bit value.
    private func wideAtom(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: bigEndian(UInt32(1)))
        data.append(contentsOf: Array(type.utf8))
        data.append(contentsOf: bigEndian(UInt64(payload.count + 16)))
        data.append(payload)
        return data
    }

    private func wideAtomHeader(_ type: String, declaredSize: UInt64) -> Data {
        var data = Data()
        data.append(contentsOf: bigEndian(UInt32(1)))
        data.append(contentsOf: Array(type.utf8))
        data.append(contentsOf: bigEndian(declaredSize))
        return data
    }

    private func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func recording(
        payload: Data?,
        tracks: Int = 1,
        transcriptTrack: Int = 0,
        wideTranscriptAtom: Bool = false
    ) -> Data {
        var traks = Data()
        for index in 0..<tracks {
            var inner = atom("tkhd", Data(repeating: 0, count: 84))
            if let payload, index == transcriptTrack {
                let transcript = wideTranscriptAtom ? wideAtom("tsrp", payload) : atom("tsrp", payload)
                inner.append(atom("udta", transcript))
            }
            traks.append(atom("trak", inner))
        }

        var file = atom("ftyp", Data("M4A ".utf8) + Data(repeating: 0, count: 4))
        file.append(atom("moov", atom("mvhd", Data(repeating: 0, count: 100)) + traks))
        file.append(atom("mdat", Data(repeating: 0x11, count: 4_096)))
        return file
    }
}
