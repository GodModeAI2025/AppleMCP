import AVFoundation
import Foundation
import XCTest
@testable import M3MCPApp

final class VoiceMemosRecordingSecurityTests: XCTestCase {
    func testResolvedRecordingRejectsLaterRegularFileReplacementBeforeRead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingURL = root.appendingPathComponent("memo.m4a")
        try Data("trusted-recording".utf8).write(to: recordingURL)

        let recording = try XCTUnwrap(
            SecureVoiceMemoRecording.resolve(
                directory: root,
                filename: recordingURL.lastPathComponent
            )
        )
        let original = root.appendingPathComponent("original.m4a")
        try FileManager.default.moveItem(at: recordingURL, to: original)
        let replacement = Data("replacement-must-not-be-read".utf8)
        try replacement.write(to: recordingURL)

        XCTAssertThrowsError(try recording.read(maximumBytes: 1_024))
        XCTAssertEqual(try Data(contentsOf: recordingURL), replacement)
    }

    func testRecordingResolutionAndReopenRejectSymlinks() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("protected.m4a")
        let recordingURL = root.appendingPathComponent("memo.m4a")
        try Data("do-not-read".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: recordingURL,
            withDestinationURL: target
        )

        XCTAssertNil(
            SecureVoiceMemoRecording.resolve(
                directory: root,
                filename: recordingURL.lastPathComponent
            )
        )

        try FileManager.default.removeItem(at: recordingURL)
        try Data("trusted-recording".utf8).write(to: recordingURL)
        let recording = try XCTUnwrap(
            SecureVoiceMemoRecording.resolve(
                directory: root,
                filename: recordingURL.lastPathComponent
            )
        )
        try FileManager.default.removeItem(at: recordingURL)
        try FileManager.default.createSymbolicLink(
            at: recordingURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(try recording.read(maximumBytes: 1_024))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "do-not-read")
    }

    func testDescriptorURLRemainsBoundToOpenedRecordingAcrossPathSwap() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingURL = root.appendingPathComponent("memo.m4a")
        let trusted = Data("trusted-descriptor".utf8)
        try trusted.write(to: recordingURL)
        let recording = try XCTUnwrap(
            SecureVoiceMemoRecording.resolve(
                directory: root,
                filename: recordingURL.lastPathComponent
            )
        )

        let input = try recording.openVerifiedAudioInput()
        let original = root.appendingPathComponent("original.m4a")
        try FileManager.default.moveItem(at: recordingURL, to: original)
        try Data("replacement".utf8).write(to: recordingURL)
        let observed = try Data(contentsOf: input.url)

        XCTAssertEqual(observed, trusted)
    }

    func testDescriptorURLIsConsumableByAVFoundation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingURL = root.appendingPathComponent("memo.caf")
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        var writer: AVAudioFile? = try AVAudioFile(
            forWriting: recordingURL,
            settings: format.settings
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)
        )
        buffer.frameLength = 160
        try writer?.write(from: buffer)
        writer = nil

        let recording = try XCTUnwrap(
            SecureVoiceMemoRecording.resolve(
                directory: root,
                filename: recordingURL.lastPathComponent
            )
        )
        let input = try recording.openVerifiedAudioInput()
        let options = input.mimeType.map { [AVURLAssetOverrideMIMETypeKey: $0] }
        let asset = AVURLAsset(url: input.url, options: options)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let decoder = try await BoundedLegacyAudioDecoder.make(
            url: input.url,
            mimeType: input.mimeType
        )
        defer { decoder.cancel() }
        var decodedFrames: AVAudioFramePosition = 0
        while let buffer = try decoder.next() {
            XCTAssertEqual(buffer.format.sampleRate, 16_000, accuracy: 0.001)
            XCTAssertEqual(buffer.format.channelCount, 1)
            decodedFrames += AVAudioFramePosition(buffer.frameLength)
        }

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(decodedFrames, 160)
    }

    private func makeRoot() throws -> URL {
        let root = URL(
            fileURLWithPath: "/private/tmp/m3-voice-recording-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}
