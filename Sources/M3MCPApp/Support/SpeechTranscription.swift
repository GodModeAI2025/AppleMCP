import AVFoundation
import Foundation
import Speech

enum TranscriptionFailure: Error, LocalizedError {
    case requiresNewerOS
    case unavailable
    case unsupportedLocale(requested: String)
    case unsupportedAudio(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .requiresNewerOS:
            return "Transcription requires macOS 26 or newer. Memo metadata is still available on this system."
        case .unavailable:
            return "The on-device speech model is not available on this Mac."
        case .unsupportedLocale(let requested):
            return "No on-device speech model matches the locale \(requested)."
        case .unsupportedAudio(let detail):
            return "Unsupported audio format: \(detail)"
        case .failed(let detail):
            return detail
        }
    }
}

/// Transcribes recordings with Apple's on-device speech models.
///
/// `SpeechTranscriber` / `SpeechAnalyzer` are the Apple Intelligence speech stack introduced in
/// macOS 26 — the same engine Voice Memos and Notes use for their own transcripts. Nothing leaves
/// the machine and no third-party recogniser is involved.
///
/// AppleMCP has to do this itself: Voice Memos computes transcripts lazily inside the app and
/// persists nothing on disk, so a memo recorded on iPhone has no transcript to read on the Mac.
enum SpeechTranscription {
    static var isSupported: Bool {
        if #available(macOS 26, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    /// Human-readable capability line for `permissions_status`.
    static var statusDescription: String {
        if #available(macOS 26, *) {
            return SpeechTranscriber.isAvailable
                ? "On-device Apple speech model available."
                : "On-device Apple speech model unavailable on this Mac."
        }
        return "Transcription requires macOS 26; metadata-only on this system."
    }

    static func transcribe(url: URL, locale: Locale) async throws -> String {
        guard #available(macOS 26, *) else {
            throw TranscriptionFailure.requiresNewerOS
        }
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionFailure.unavailable
        }

        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        guard let resolved else {
            throw TranscriptionFailure.unsupportedLocale(requested: locale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)

        // First use of a locale downloads its model. `assetInstallationRequest` returns nil once
        // everything needed is already installed.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionFailure.failed("Could not install the speech model for \(resolved.identifier): \(error.localizedDescription)")
        }

        let audioFile = try await openAudio(at: url)

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Start collecting before analysis so no early results are dropped. The sequence ends
        // when the analyzer finishes.
        let collector = Task {
            var transcript = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                transcript += result.text
            }
            return String(transcript.characters)
        }

        do {
            let lastSample = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSample {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw TranscriptionFailure.failed("Transcription failed: \(error.localizedDescription)")
        }

        do {
            return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TranscriptionFailure.failed("Could not read transcription results: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio input

    /// Opens the recording as an `AVAudioFile`, transcoding first when the container needs it.
    ///
    /// Most memos are plain `.m4a`. Edited recordings are stored as `.qta`, which `AVAudioFile`
    /// cannot always open directly, so those are decoded through `AVAssetReader` into a scratch
    /// CAF file first.
    private static func openAudio(at url: URL) async throws -> AVAudioFile {
        if let file = try? AVAudioFile(forReading: url) {
            AppLogger.log("Transcription: \(url.lastPathComponent) opened directly, format \(file.processingFormat), frames \(file.length)")
            return file
        }
        AppLogger.log("Transcription: \(url.lastPathComponent) not readable by AVAudioFile — falling back to AVAssetReader transcode")
        let transcoded = try await transcodeToScratchFile(url: url)
        do {
            return try AVAudioFile(forReading: transcoded)
        } catch {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) (\(error.localizedDescription))")
        }
    }

    private static func transcodeToScratchFile(url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) could not be opened by AVFoundation (\(error.localizedDescription))")
        }

        guard let track = tracks.first else {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) contains no audio track")
        }

        // Edited recordings can carry more than one audio track — a stereo mix alongside a
        // multichannel spatial one. Which track comes first is not guaranteed, so log the choice;
        // transcribing the wrong one would silently degrade the transcript rather than fail.
        if tracks.count > 1 {
            AppLogger.log("Transcription: \(url.lastPathComponent) has \(tracks.count) audio tracks; using track id \(track.trackID)")
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) is not readable (\(error.localizedDescription))")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) cannot be decoded to PCM")
        }
        reader.add(output)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("m3mcp-transcode-\(UUID().uuidString).caf")

        guard reader.startReading() else {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) could not be read (\(reader.error?.localizedDescription ?? "unknown error"))")
        }

        var writer: AVAudioFile?
        var writeFailure: Error?

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
                  let format = AVAudioFormat(streamDescription: streamDescription) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            if writer == nil {
                do {
                    writer = try AVAudioFile(forWriting: destination, settings: format.settings)
                } catch {
                    throw TranscriptionFailure.unsupportedAudio("Could not create a scratch file for \(url.lastPathComponent) (\(error.localizedDescription))")
                }
            }

            if let buffer = pcmBuffer(from: sampleBuffer, format: format) {
                do {
                    try writer?.write(from: buffer)
                } catch {
                    // Keep the first failure. Swallowing these would yield a zero-frame file that
                    // reads back fine and transcribes to an empty string — a wrong answer dressed
                    // up as "no speech in this recording".
                    if writeFailure == nil { writeFailure = error }
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        if reader.status == .failed {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) failed while decoding (\(reader.error?.localizedDescription ?? "unknown error"))")
        }
        guard let writer else {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) produced no decodable audio")
        }
        if let writeFailure {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) could not be transcoded (\(writeFailure.localizedDescription))")
        }
        // An empty scratch file would transcribe to "" and be reported as silence.
        guard writer.length > 0 else {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) decoded to an empty audio stream")
        }

        return destination
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

/// Content-addressed transcript cache.
///
/// Keyed on `ZAUDIODIGEST` — a 32-byte SHA-256 of the recording that Voice Memos already maintains.
/// That survives file touches, re-syncs, and iCloud evict/restore cycles which would all
/// spuriously invalidate an mtime check. Transcribing a four-minute memo is not cheap, so repeat
/// reads should never pay for it twice.
enum TranscriptCache {
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("M3MCP/transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func location(forDigest digest: String) -> URL? {
        guard !digest.isEmpty else { return nil }
        return directory?.appendingPathComponent("\(digest).txt")
    }

    static func read(digest: String?) -> String? {
        guard let digest, let url = location(forDigest: digest) else { return nil }
        guard let cached = try? String(contentsOf: url, encoding: .utf8), !cached.isEmpty else {
            return nil
        }
        return cached
    }

    static func has(digest: String?) -> Bool {
        read(digest: digest) != nil
    }

    static func write(_ transcript: String, digest: String?) {
        // Never cache an empty transcript. A recording with no speech, a transcription that failed
        // silently, and a model that was still downloading all produce "" — persisting that would
        // pin the memo to an empty result forever, and the miss would look like a cache bug.
        guard !transcript.isEmpty, let digest, let url = location(forDigest: digest) else { return }
        try? transcript.write(to: url, atomically: true, encoding: .utf8)
    }
}
