import AVFoundation
import Foundation
import M3MCPCore

/// Pull-driven, resource-bounded PCM decoding for the legacy Speech request.
///
/// The input URL is the provider's retained `/dev/fd` descriptor URL, so AVAssetReader opens the
/// already-verified recording rather than resolving the mutable Voice Memos library pathname.
final class BoundedLegacyAudioDecoder: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let sourceName: String
    private let stateLock = NSLock()
    private let decodeLock = NSLock()
    private var cancellationRequested = false
    private var meter = SpeechTranscodePolicy.Meter()

    static func make(
        url: URL,
        mimeType: String?
    ) async throws -> BoundedLegacyAudioDecoder {
        let options = mimeType.map { [AVURLAssetOverrideMIMETypeKey: $0] }
        let asset = AVURLAsset(url: url, options: options)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionFailure.unsupportedAudio(
                "the verified recording descriptor could not be opened by AVFoundation "
                    + "(\(error.localizedDescription))"
            )
        }
        try Task.checkCancellation()

        guard let track = tracks.first else {
            throw TranscriptionFailure.unsupportedAudio(
                "the verified recording contains no audio track"
            )
        }

        let duration: CMTime
        let formatDescriptions: [CMFormatDescription]
        do {
            duration = try await track.load(.timeRange).duration
            try Task.checkCancellation()
            formatDescriptions = try await track.load(.formatDescriptions)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionFailure.unsupportedAudio(
                "the verified recording metadata could not be bounded "
                    + "(\(error.localizedDescription))"
            )
        }

        let durationSeconds = CMTimeGetSeconds(duration)
        let sampleRate = formatDescriptions.compactMap { description -> Double? in
            guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
                return nil
            }
            let value = stream.pointee.mSampleRate
            return value.isFinite && value > 0 ? value : nil
        }.max() ?? .nan

        do {
            try SpeechTranscodePolicy.validateSource(
                durationSeconds: durationSeconds,
                sampleRate: sampleRate
            )
        } catch let violation as SpeechTranscodePolicy.Violation {
            throw TranscriptionFailure.unsupportedAudio(violation.localizedDescription)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscriptionFailure.unsupportedAudio(
                "the verified recording is not readable (\(error.localizedDescription))"
            )
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: SpeechTranscodePolicy.outputSampleRate,
            AVNumberOfChannelsKey: SpeechTranscodePolicy.outputChannelCount
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else {
            throw TranscriptionFailure.unsupportedAudio(
                "the verified recording cannot be decoded to bounded PCM"
            )
        }
        reader.add(output)
        return try BoundedLegacyAudioDecoder(
            reader: reader,
            output: output,
            sourceName: "verified Voice Memo descriptor"
        )
    }

    private init(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        sourceName: String
    ) throws {
        self.reader = reader
        self.output = output
        self.sourceName = sourceName
        guard reader.startReading() else {
            throw TranscriptionFailure.unsupportedAudio(
                "\(sourceName) could not be read "
                    + "(\(reader.error?.localizedDescription ?? "unknown error"))"
            )
        }
    }

    deinit {
        cancel()
    }

    func next() throws -> AVAudioPCMBuffer? {
        decodeLock.lock()
        defer { decodeLock.unlock() }

        while true {
            try checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                try checkCancellation()
                if reader.status == .failed {
                    throw TranscriptionFailure.unsupportedAudio(
                        "\(sourceName) failed while decoding "
                            + "(\(reader.error?.localizedDescription ?? "unknown error"))"
                    )
                }
                return nil
            }

            defer { CMSampleBufferInvalidate(sampleBuffer) }
            try checkCancellation()

            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                    formatDescription
                  ),
                  let format = AVAudioFormat(streamDescription: streamDescription) else {
                try record(frames: 0, bytes: 0)
                continue
            }

            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0 else {
                try record(frames: 0, bytes: 0)
                continue
            }

            let bytesPerFrame = UInt64(streamDescription.pointee.mBytesPerFrame)
            let bufferCount = format.isInterleaved ? UInt64(1) : UInt64(format.channelCount)
            let decodedBytes: UInt64
            do {
                decodedBytes = try SpeechTranscodePolicy.preflightBufferAllocation(
                    frameCount: frameCount,
                    bytesPerFrame: bytesPerFrame,
                    bufferCount: bufferCount,
                    meter: &meter
                )
            } catch let violation as SpeechTranscodePolicy.Violation {
                throw TranscriptionFailure.unsupportedAudio(
                    "\(sourceName): \(violation.localizedDescription)"
                )
            }

            guard frameCount <= Int(Int32.max) else {
                throw TranscriptionFailure.unsupportedAudio(
                    "\(sourceName): sample-buffer frame count exceeds Int32"
                )
            }
            let capacity = AVAudioFrameCount(frameCount)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: capacity
            ) else {
                throw TranscriptionFailure.unsupportedAudio(
                    "\(sourceName) could not allocate a bounded PCM buffer"
                )
            }
            buffer.frameLength = capacity
            guard pcmByteCount(buffer) <= decodedBytes else {
                throw TranscriptionFailure.unsupportedAudio(
                    "\(sourceName): decoded PCM allocation exceeded its preflight"
                )
            }

            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: buffer.mutableAudioBufferList
            )
            guard status == noErr else {
                throw TranscriptionFailure.unsupportedAudio(
                    "\(sourceName) could not copy decoded PCM (OSStatus \(status))"
                )
            }
            try checkCancellation()
            return buffer
        }
    }

    /// AVAssetReader owns its cancellation synchronization, so this does not wait for a decoder
    /// call that may currently be blocked inside `copyNextSampleBuffer`.
    func cancel() {
        stateLock.lock()
        let shouldCancel = !cancellationRequested
        cancellationRequested = true
        stateLock.unlock()
        if shouldCancel {
            reader.cancelReading()
        }
    }

    private func checkCancellation() throws {
        stateLock.lock()
        let cancelled = cancellationRequested
        stateLock.unlock()
        if cancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func record(frames: UInt64, bytes: UInt64) throws {
        do {
            try meter.record(decodedFrames: frames, decodedPCMBytes: bytes)
        } catch let violation as SpeechTranscodePolicy.Violation {
            throw TranscriptionFailure.unsupportedAudio(
                "\(sourceName): \(violation.localizedDescription)"
            )
        }
    }

    private func pcmByteCount(_ buffer: AVAudioPCMBuffer) -> UInt64 {
        var total: UInt64 = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        ) {
            let addition = total.addingReportingOverflow(
                UInt64(audioBuffer.mDataByteSize)
            )
            if addition.overflow { return UInt64.max }
            total = addition.partialValue
        }
        return total
    }
}
