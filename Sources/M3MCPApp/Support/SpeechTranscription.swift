import AVFoundation
import Darwin
import Foundation
import M3MCPCore
import Speech

enum TranscriptionFailure: Error, LocalizedError {
    case requiresNewerOS
    case unavailable
    case unsupportedLocale(requested: String)
    case unsupportedAudio(String)
    case timedOut(TimeInterval)
    case resourceBusy(maximumConcurrentOperations: Int)
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
        case .timedOut(let seconds):
            return "On-device speech analysis did not finish within \(String(format: "%.0f", seconds)) seconds."
        case .resourceBusy(let maximum):
            return "Another on-device speech analysis is still active or finishing after cancellation "
                + "(limit \(maximum)). Retry after it has stopped."
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
    /// SpeechAnalyzer cancellation is cooperative. Keep this lease occupied until the analyzer
    /// task actually exits so repeated timeouts cannot accumulate native recognition work.
    private static let operationAdmission = AsyncOperationAdmission(maximumConcurrentOperations: 1)

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

    static func transcribe(
        input: VerifiedVoiceMemoAudioInput,
        locale: Locale,
        budget: VoiceMemoTranscriptionBudget
    ) async throws -> String {
        do {
            return try await AsyncOperationDeadline.run(
                budget: budget,
                admission: operationAdmission
            ) {
                try await transcribeWithoutDeadline(
                    input: input,
                    locale: locale
                )
            }
        } catch let deadline as AsyncOperationDeadline.TimedOut {
            throw TranscriptionFailure.timedOut(deadline.seconds)
        } catch let busy as AsyncOperationDeadline.ResourceBusy {
            throw TranscriptionFailure.resourceBusy(
                maximumConcurrentOperations: busy.maximumConcurrentOperations
            )
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    private static func transcribeWithoutDeadline(
        input: VerifiedVoiceMemoAudioInput,
        locale: Locale
    ) async throws -> String {
        // The asset URL is descriptor-backed. Keep the descriptor owner alive until the analyzer
        // has really exited; the caller may already have received a deadline result by then.
        defer { withExtendedLifetime(input) {} }

        guard #available(macOS 26, *) else {
            throw TranscriptionFailure.requiresNewerOS
        }
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionFailure.unavailable
        }

        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        try Task.checkCancellation()
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionFailure.failed("Could not install the speech model for \(resolved.identifier): \(error.localizedDescription)")
        }

        try Task.checkCancellation()
        let preparedAudio = try await openAudio(
            at: input.url,
            mimeType: input.mimeType
        )
        return try await analyze(preparedAudio, with: transcriber)
    }

    @available(macOS 26, *)
    private static func analyze(_ input: PreparedAudio, with transcriber: SpeechTranscriber) async throws -> String {
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

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let lastSample: CMTime?
                switch input {
                case .file(let audioFile):
                    lastSample = try await analyzer.analyzeSequence(from: audioFile)
                case .boundedStream(let decoder):
                    defer { decoder.cancel() }
                    let inputs = AsyncThrowingStream<AnalyzerInput, Error> {
                        try decoder.next()
                    }
                    lastSample = try await analyzer.analyzeSequence(inputs)
                }
                try Task.checkCancellation()
                if let lastSample {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch is CancellationError {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw CancellationError()
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw TranscriptionFailure.failed("Transcription failed: \(error.localizedDescription)")
            }

            do {
                return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch is CancellationError {
                await analyzer.cancelAndFinishNow()
                throw CancellationError()
            } catch {
                throw TranscriptionFailure.failed("Could not read transcription results: \(error.localizedDescription)")
            }
        } onCancel: {
            collector.cancel()
            input.cancel()
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    // MARK: - Audio input

    /// Opens the recording as an `AVAudioFile`, or prepares a bounded pull stream when needed.
    ///
    /// Most memos are plain `.m4a`. Edited recordings are stored as `.qta`, which `AVAudioFile`
    /// cannot always open directly, so those are decoded through `AVAssetReader` directly into
    /// SpeechAnalyzer without creating a decoded filesystem copy.
    @available(macOS 26, *)
    private enum PreparedAudio: @unchecked Sendable {
        case file(AVAudioFile)
        case boundedStream(BoundedAnalyzerInputDecoder)

        func cancel() {
            if case .boundedStream(let decoder) = self {
                decoder.cancel()
            }
        }
    }

    @available(macOS 26, *)
    private static func openAudio(at url: URL, mimeType: String?) async throws -> PreparedAudio {
        // Descriptor URLs have no filename extension. AVAudioFile cannot accept the MIME override
        // AVURLAsset supports, so verified descriptor inputs always use the bounded reader path.
        if mimeType == nil, let file = try? AVAudioFile(forReading: url) {
            AppLogger.log("Transcription: \(url.lastPathComponent) opened directly, format \(file.processingFormat), frames \(file.length)")
            return .file(file)
        }
        AppLogger.log("Transcription: \(url.lastPathComponent) not readable by AVAudioFile — falling back to bounded AVAssetReader streaming")
        return .boundedStream(
            try await makeBoundedInputDecoder(url: url, mimeType: mimeType)
        )
    }

    @available(macOS 26, *)
    private static func makeBoundedInputDecoder(
        url: URL,
        mimeType: String?
    ) async throws -> BoundedAnalyzerInputDecoder {
        let options = mimeType.map { [AVURLAssetOverrideMIMETypeKey: $0] }
        let asset = AVURLAsset(url: url, options: options)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) could not be opened by AVFoundation (\(error.localizedDescription))")
        }
        try Task.checkCancellation()

        guard let track = tracks.first else {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) contains no audio track")
        }

        // Edited recordings can carry more than one audio track — a stereo mix alongside a
        // multichannel spatial one. Which track comes first is not guaranteed, so log the choice;
        // transcribing the wrong one would silently degrade the transcript rather than fail.
        if tracks.count > 1 {
            AppLogger.log("Transcription: \(url.lastPathComponent) has \(tracks.count) audio tracks; using track id \(track.trackID)")
        }

        try Task.checkCancellation()
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
                "\(url.lastPathComponent) metadata could not be bounded (\(error.localizedDescription))"
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
            throw TranscriptionFailure.unsupportedAudio(
                "\(url.lastPathComponent): \(violation.localizedDescription)"
            )
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
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: SpeechTranscodePolicy.outputSampleRate,
            AVNumberOfChannelsKey: SpeechTranscodePolicy.outputChannelCount
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else {
            throw TranscriptionFailure.unsupportedAudio("\(url.lastPathComponent) cannot be decoded to PCM")
        }
        reader.add(output)
        return try BoundedAnalyzerInputDecoder(
            reader: reader,
            output: output,
            sourceName: url.lastPathComponent
        )
    }

    /// Pull-driven decoding gives SpeechAnalyzer one bounded buffer at a time. The unfolding
    /// producer cannot outrun the analyzer or accumulate decoded private audio in memory.
    @available(macOS 26, *)
    private final class BoundedAnalyzerInputDecoder: @unchecked Sendable {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let sourceName: String
        private let stateLock = NSLock()
        private let decodeLock = NSLock()
        private var cancellationRequested = false
        private var meter = SpeechTranscodePolicy.Meter()

        init(
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

        func next() throws -> AnalyzerInput? {
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

                let input: AnalyzerInput?
                do {
                    defer { CMSampleBufferInvalidate(sampleBuffer) }
                    try checkCancellation()

                    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                            formatDescription
                          ),
                          let format = AVAudioFormat(streamDescription: streamDescription) else {
                        try record(frames: 0, bytes: 0)
                        input = nil
                        continue
                    }

                    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
                    guard frameCount > 0 else {
                        try record(frames: 0, bytes: 0)
                        input = nil
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

                    // Charge frames and allocation bytes before converting to UInt32/Int32 or
                    // allocating AVAudioPCMBuffer. The production frame limit is far below both
                    // integer maxima, closing the corrupt-count trap before either conversion.
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
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    input = AnalyzerInput(
                        buffer: buffer,
                        bufferStartTime: timestamp.isValid ? timestamp : nil
                    )
                }
                if let input {
                    return input
                }
            }
        }

        /// Does not wait for a potentially blocked copyNextSampleBuffer; AVAssetReader owns the
        /// cancellation synchronization. This keeps the deadline coordinator's onCancel path fast.
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
}

/// Content-addressed transcript cache.
///
/// Keyed on `ZAUDIODIGEST` — a 32-byte SHA-256 of the recording that Voice Memos already maintains.
/// That survives file touches, re-syncs, and iCloud evict/restore cycles which would all
/// spuriously invalidate an mtime check. Transcribing a four-minute memo is not cheap, so repeat
/// reads should never pay for it twice.
enum TranscriptCache {
    static let maximumCacheBytes = 16 * 1_024 * 1_024

    /// Tests inject a private base directory. Production always uses the system-provided user
    /// Application Support directory.
    private static func resolvedBaseDirectory(_ override: URL?) -> URL? {
        if let override { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    static func read(digest: String?, baseDirectory: URL? = nil) -> String? {
        guard let filename = filename(forDigest: digest),
              let directory = openCacheDirectory(baseDirectory: baseDirectory) else {
            return nil
        }
        defer { Darwin.close(directory) }

        let descriptor = filename.withCString { name in
            openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumCacheBytes) else {
            return nil
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.read(upToCount: maximumCacheBytes + 1) ?? Data()
        } catch {
            return nil
        }
        guard data.count <= maximumCacheBytes,
              let cached = String(data: data, encoding: .utf8),
              !cached.isEmpty else {
            return nil
        }
        return cached
    }

    static func has(digest: String?, baseDirectory: URL? = nil) -> Bool {
        read(digest: digest, baseDirectory: baseDirectory) != nil
    }

    static func write(_ transcript: String, digest: String?, baseDirectory: URL? = nil) {
        // Never cache an empty transcript. A recording with no speech, a transcription that failed
        // silently, and a model that was still downloading all produce "" — persisting that would
        // pin the memo to an empty result forever, and the miss would look like a cache bug.
        let data = Data(transcript.utf8)
        guard !data.isEmpty,
              data.count <= maximumCacheBytes,
              let filename = filename(forDigest: digest),
              let directory = openCacheDirectory(baseDirectory: baseDirectory) else {
            return
        }
        defer { Darwin.close(directory) }

        let temporaryName = ".m3mcp-transcript-\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString { name in
            openat(
                directory,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { return }

        var keepTemporary = true
        defer {
            Darwin.close(descriptor)
            if keepTemporary {
                _ = temporaryName.withCString { unlinkat(directory, $0, 0) }
            }
        }

        guard writeAll(data, to: descriptor), fsync(descriptor) == 0 else { return }
        let renamed = temporaryName.withCString { source in
            filename.withCString { destination in
                renameat(directory, source, directory, destination)
            }
        }
        guard renamed == 0 else { return }
        keepTemporary = false
        _ = fsync(directory)
    }

    private static func filename(forDigest digest: String?) -> String? {
        guard let digest, M3InputValidation.isSHA256HexDigest(digest) else { return nil }
        return "\(digest.lowercased()).txt"
    }

    /// Opens every absolute-path component with `O_NOFOLLOW`, then creates only the two owned cache
    /// components via `mkdirat`. No path-based chmod/write is used after validation, so a same-user
    /// symlink cannot redirect Full Disk Access into an unrelated protected tree.
    private static func openCacheDirectory(baseDirectory: URL?) -> Int32? {
        guard let baseURL = resolvedBaseDirectory(baseDirectory),
              let base = openAbsoluteDirectory(baseURL),
              isOwnedDirectory(base) else {
            return nil
        }
        defer { Darwin.close(base) }

        guard let application = openOrCreateOwnedDirectory(named: "M3MCP", under: base) else {
            return nil
        }
        defer { Darwin.close(application) }
        return openOrCreateOwnedDirectory(named: "transcripts", under: application)
    }

    private static func openAbsoluteDirectory(_ url: URL) -> Int32? {
        guard url.isFileURL else { return nil }
        // `standardizedFileURL` rewrites macOS's real `/private/tmp` path to the `/tmp` symlink.
        // That makes the intentional `O_NOFOLLOW` traversal reject an otherwise safe injected
        // base directory with `ENOTDIR`. Keep the caller's absolute spelling and reject traversal
        // components explicitly instead of canonicalizing through filesystem aliases.
        let path = url.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }

        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { return nil }

        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard component != ".", component != ".." else {
                Darwin.close(current)
                return nil
            }
            let next = String(component).withCString { name in
                openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            Darwin.close(current)
            guard next >= 0 else { return nil }
            current = next
        }
        return current
    }

    private static func openOrCreateOwnedDirectory(named name: String, under parent: Int32) -> Int32? {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var descriptor = name.withCString { openat(parent, $0, flags) }
        if descriptor < 0, errno == ENOENT {
            let created = name.withCString { mkdirat(parent, $0, S_IRWXU) }
            guard created == 0 || errno == EEXIST else { return nil }
            descriptor = name.withCString { openat(parent, $0, flags) }
        }
        guard descriptor >= 0, isOwnedDirectory(descriptor), fchmod(descriptor, S_IRWXU) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return nil
        }
        return descriptor
    }

    private static func isOwnedDirectory(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0
            && metadata.st_uid == getuid()
            && metadata.st_mode & S_IFMT == S_IFDIR
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, base, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                remaining -= written
                base = base.advanced(by: written)
            }
            return true
        }
    }
}
