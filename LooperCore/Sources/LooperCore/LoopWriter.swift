import AVFoundation

/// Writes a looped video by copying the clip's compressed samples into one continuous
/// track, shifting each copy's timestamps by the clip duration.
///
/// Why not `AVAssetExportSession` passthrough of the composition: that writes one
/// edit-list entry per copy, and ffmpeg (close to what YouTube ingests with) misreads
/// the first entry when the clip has B-frames, holding a frame for two extra frames at
/// the first seam and shifting everything after it. Rewriting timestamps instead gives
/// a file shaped like the source clip itself: a single continuous sample table and at
/// most one edit (B-frame start offset, plus trimming the last copy's end), which every
/// decoder handles. Samples are still copied byte for byte, never re-encoded.
///
/// M3 adds audio inputs to the same writer (passthrough can't mix audio either).
public struct LoopWriter: Sendable {
    /// How often progress is reported.
    public var progressInterval: Duration = .milliseconds(250)

    public init() {}

    public func export(
        clip: ClipInfo,
        plan: LoopPlan,
        fileType: AVFileType = .mp4,
        to outputURL: URL,
        overwrite: Bool = false,
        progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        let partialURL = try OutputFile.prepare(outputURL, overwrite: overwrite)

        let asset = AVURLAsset(url: clip.url, options: ClipInfo.assetOptions)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipError.noVideoTrack
        }
        let formats = try await track.load(.formatDescriptions)

        let writer = try AVAssetWriter(outputURL: partialURL, fileType: fileType)
        // outputSettings nil = append compressed samples as they are (no re-encode).
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        input.expectsMediaDataInRealTime = false
        input.transform = clip.preferredTransform
        input.mediaTimeScale = clip.timescale
        guard writer.canAdd(input) else {
            throw ExportError.incompatible("can't write \(clip.codec) video to \(fileType.rawValue)")
        }
        writer.add(input)
        // Moving the header to the front costs a second pass over a huge file; YouTube
        // doesn't need it.
        writer.shouldOptimizeForNetworkUse = false

        // Raw sample timestamps can start after zero: B-frame clips store the first
        // shown frame a frame or two into the media timeline and use an edit to hide
        // the gap. Find that start and keep the same structure in the output (session
        // from mediaStart), so decode timestamps never go negative.
        let mediaStart = try Self.readSamples(of: track, in: asset)
            .map(CMSampleBufferGetPresentationTimeStamp)
            .reduce(CMTime.positiveInfinity) { $1 < $0 ? $1 : $0 }
        guard mediaStart.isNumeric else { throw ClipError.emptyVideoTrack }

        guard writer.startWriting() else {
            throw ExportError.failed(writer.error?.localizedDescription ?? "couldn't start writing")
        }
        writer.startSession(atSourceTime: mediaStart)

        let pump = SamplePump(
            input: input, track: track, asset: asset, plan: plan, mediaStart: mediaStart,
            reporter: ProgressReporter(total: plan.duration, interval: progressInterval, report: progress))
        do {
            try await pump.run()
        } catch {
            let detail = writer.status == .failed ? writer.error : nil
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partialURL)
            if let detail, !(error is CancellationError) { throw ExportError.failed(detail.localizedDescription) }
            throw error
        }

        // Ending the session at the exact target trims any decode-only samples of the
        // last copy (frames past the cut that earlier B-frames reference) via the edit list.
        writer.endSession(atSourceTime: mediaStart + plan.duration)
        await writer.finishWriting()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: partialURL)
            throw ExportError.failed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
        try FileManager.default.moveItem(at: partialURL, to: outputURL)
        progress(ExportProgress(fractionCompleted: 1, estimatedTimeRemaining: 0))
    }

    /// All compressed samples of one copy of the clip, in decode order, with their raw
    /// media timestamps. One reader per copy keeps memory flat (only one copy is held
    /// at a time) at the cost of reopening a small file, which the OS has cached.
    static func readSamples(of track: AVAssetTrack, in asset: AVAsset) throws -> [CMSampleBuffer] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.failed(reader.error?.localizedDescription ?? "couldn't read the clip")
        }
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { samples.append(sample) }
        }
        if reader.status == .failed {
            throw ExportError.failed(reader.error?.localizedDescription ?? "reading the clip failed")
        }
        return samples
    }

    /// For the trimmed last copy: samples in decode order up to the last one that is
    /// shown before `cut`. Anything earlier in decode order is kept even if it's shown
    /// after the cut, because B-frames before the cut may reference it; the session end
    /// hides those frames.
    static func samplesNeeded(_ samples: [CMSampleBuffer], toShowFramesBefore cut: CMTime) -> [CMSampleBuffer] {
        guard let last = samples.lastIndex(where: { CMSampleBufferGetPresentationTimeStamp($0) < cut }) else {
            return []
        }
        return Array(samples[...last])
    }

    /// A copy of `sample` with presentation and decode times moved by `offset`.
    static func retimed(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in timings.indices {
            timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + offset
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = timings[i].decodeTimeStamp + offset
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw ExportError.failed("couldn't retime a sample (\(status))") }
        return copy
    }

}

/// Feeds retimed samples to the writer input from AVFoundation's pull callback
/// (`requestMediaDataWhenReady`), the fastest way to keep the writer busy.
///
/// @unchecked Sendable: all mutable state is touched only on `queue` (the callback
/// queue), except the cancellation flag, which is lock-protected.
private final class SamplePump: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let track: AVAssetTrack
    private let asset: AVAsset
    private let plan: LoopPlan
    private let mediaStart: CMTime
    private var reporter: ProgressReporter
    private let queue = DispatchQueue(label: "looper.loopwriter.video")

    private var copyIndex = 0
    private var pending: [CMSampleBuffer] = []
    private var pendingIndex = 0
    private var offset = CMTime.zero
    private var continuation: CheckedContinuation<Void, Error>?

    private let lock = NSLock()
    private var cancelled = false

    init(input: AVAssetWriterInput, track: AVAssetTrack, asset: AVAsset, plan: LoopPlan,
         mediaStart: CMTime, reporter: ProgressReporter) {
        self.input = input
        self.track = track
        self.asset = asset
        self.plan = plan
        self.mediaStart = mediaStart
        self.reporter = reporter
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.sync { self.continuation = continuation }
                input.requestMediaDataWhenReady(on: queue) { [self] in pump() }
            }
        } onCancel: {
            lock.lock(); cancelled = true; lock.unlock()
        }
    }

    private enum Step { case appended, done, failed(Error) }

    private func pump() {
        guard continuation != nil else { return }
        while input.isReadyForMoreMediaData {
            let isCancelled = lock.withLock { cancelled }
            if isCancelled { return finish(.failure(CancellationError())) }
            // Drain autoreleased AVFoundation objects per sample; otherwise they pile up
            // over hundreds of thousands of samples on this long-lived callback.
            let step: Step = autoreleasepool {
                do {
                    guard let sample = try nextSample() else { return .done }
                    return input.append(sample) ? .appended : .failed(ExportError.failed("couldn't append a sample"))
                } catch {
                    return .failed(error)
                }
            }
            switch step {
            case .appended: continue
            case .done: return finish(.success(()))
            case .failed(let error): return finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        input.markAsFinished()
        continuation?.resume(with: result)
        continuation = nil
    }

    /// The next sample in output order, retimed, loading the next copy when needed.
    private func nextSample() throws -> CMSampleBuffer? {
        while pendingIndex >= pending.count {
            guard copyIndex < plan.copyCount else { return nil }
            let samples = try LoopWriter.readSamples(of: track, in: asset)
            // Raw media times + offset: copy k occupies [k × D, (k+1) × D) after the
            // session start (mediaStart), so seams are exact.
            offset = plan.clipDuration.multiplied(by: copyIndex)
            pending = copyIndex == plan.fullCopies
                ? LoopWriter.samplesNeeded(samples, toShowFramesBefore: mediaStart + plan.remainder)
                : samples
            pendingIndex = 0
            copyIndex += 1
        }
        let sample = pending[pendingIndex]
        pendingIndex += 1
        reporter.update(position: CMSampleBufferGetPresentationTimeStamp(sample) + offset - mediaStart)
        return try LoopWriter.retimed(sample, by: offset)
    }
}

/// Throttled progress + time-remaining reports from the current output position.
struct ProgressReporter {
    let total: CMTime
    let interval: Duration
    let report: @Sendable (ExportProgress) -> Void
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var lastReport: ContinuousClock.Instant?
    private var eta = ETAEstimator()
    private var lastFraction = 0.0

    init(total: CMTime, interval: Duration, report: @escaping @Sendable (ExportProgress) -> Void) {
        self.total = total
        self.interval = interval
        self.report = report
        start = clock.now
    }

    mutating func update(position: CMTime) {
        let now = clock.now
        if let lastReport, now - lastReport < interval { return }
        lastReport = now
        // Samples arrive in decode order, so presentation times wobble by a frame or
        // two; keep the reported fraction monotonic.
        let fraction = min(max(position.seconds / total.seconds, lastFraction), 0.999)
        lastFraction = fraction
        report(ExportProgress(fractionCompleted: fraction,
                              estimatedTimeRemaining: eta.update(fraction: fraction, elapsed: (now - start).timeInterval)))
    }
}

/// Output file handling shared by exporters.
enum OutputFile {
    /// Checks the destination and returns the hidden temporary file to write into.
    /// Exporters rename it to `outputURL` only on success, so a failed or cancelled
    /// export never leaves a partial `video.mp4` behind.
    static func prepare(_ outputURL: URL, overwrite: Bool) throws -> URL {
        let files = FileManager.default
        if files.fileExists(atPath: outputURL.path) {
            guard overwrite else { throw ExportError.outputExists(outputURL) }
            try files.removeItem(at: outputURL)
        }
        let partial = partialURL(for: outputURL)
        try? files.removeItem(at: partial)
        return partial
    }

    /// Hidden file in the output folder (same volume, so the final rename is instant),
    /// e.g. `.video.partial.mp4`.
    static func partialURL(for outputURL: URL) -> URL {
        let name = "." + outputURL.deletingPathExtension().lastPathComponent + ".partial." + outputURL.pathExtension
        return outputURL.deletingLastPathComponent().appendingPathComponent(name)
    }
}
