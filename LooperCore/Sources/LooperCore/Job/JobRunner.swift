import Foundation
import os

/// Progress of a whole job: the version being written and the job overall.
public struct JobProgress: Sendable, Equatable {
    /// Index into the job's versions of the one being written.
    public let versionIndex: Int
    public let versionCount: Int
    /// Progress of the current version alone.
    public let version: ExportProgress
    /// Progress of the whole job, with an ETA for all remaining versions.
    public let overall: ExportProgress
}

/// What happened to one version of a job.
public enum VersionOutcome: Sendable, Equatable {
    case finished(URL)
    case failed(String)
    /// Stopped part way by a cancel.
    case cancelled
    /// Not started because the job was cancelled earlier.
    case skipped
}

public struct JobResult: Sendable, Equatable {
    /// One entry per version, in the job's order.
    public let outcomes: [VersionOutcome]

    public var wasCancelled: Bool { outcomes.contains(.cancelled) || outcomes.contains(.skipped) }
    public var finishedURLs: [URL] {
        outcomes.compactMap { outcome -> URL? in
            if case .finished(let url) = outcome { return url }
            return nil
        }
    }
}

/// Exports every version of a job, in order, into `<Clip name>/<Version name>/`.
///
/// The clip is loaded once and shared by all versions. A version that fails is recorded
/// and the next one still runs (one bad playlist shouldn't cost the other uploads);
/// cancelling stops the current version and skips the rest.
///
/// With `branding`, each finished version also gets its publish kit's text files
/// (`title.txt`, `description.txt`, `tags.txt`) and its choices go into the channel's
/// history. Every kit is made before the first export starts, so a template that can't
/// be filled stops the job at once instead of after hours of exporting.
///
/// Video fade to black (#44) and the thumbnail (#46, #72) are not yet written here.
public struct JobRunner: Sendable {
    public var exporter: any LoopExporting
    public var loadClip: @Sendable (URL) async throws -> ClipInfo

    public init(
        exporter: any LoopExporting = LoopWriter(),
        loadClip: @escaping @Sendable (URL) async throws -> ClipInfo = { try await ClipInfo.load(from: $0) }
    ) {
        self.exporter = exporter
        self.loadClip = loadClip
    }

    /// Runs `job`. Throws only for problems that stop the whole job before it starts
    /// (an invalid job, an unreadable clip); per-version results are in the `JobResult`.
    ///
    /// - Parameter replacing: overwrite existing `video.mp4` files; otherwise each
    ///   version writes "video 2.mp4" etc. next to an existing one.
    public func run(
        _ job: Job,
        outputFolder: URL,
        replacing: Bool = false,
        branding: Branding? = nil,
        progress: @escaping @Sendable (JobProgress) -> Void = { _ in }
    ) async throws -> JobResult {
        if let problem = job.problem { throw problem }
        let kits = try branding?.kits(for: job)
        try Task.checkCancellation()
        let clip = try await loadClip(job.clip)

        let tracker = OverallProgress(weights: job.versions.map { Double($0.duration.seconds) })
        var outcomes: [VersionOutcome] = []

        for (index, version) in job.versions.enumerated() {
            if Task.isCancelled {
                outcomes.append(.skipped)
                continue
            }
            let destination = job.videoURL(for: version, in: outputFolder)
            let url = replacing ? destination : OutputLayout.nextAvailable(destination)
            let plan = LoopPlan(clip: clip, target: version.duration)
            let audio = version.audio.hasAudio(clipHasAudio: clip.hasAudio) ? version.audio : nil
            let count = job.versions.count
            progress(tracker.report(index: index, count: count, version: ExportProgress(fractionCompleted: 0, estimatedTimeRemaining: nil)))
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await exporter.export(clip: clip, plan: plan, audio: audio, to: url, overwrite: replacing) { update in
                    progress(tracker.report(index: index, count: count, version: update))
                }
                tracker.complete(index: index)
                if let branding, let kit = kits?[index] {
                    do {
                        try kit.write(to: url.deletingLastPathComponent())
                        try branding.record(kit)
                    } catch {
                        outcomes.append(.failed("The video was written, but not its publish kit: \(error.localizedDescription)"))
                        continue
                    }
                }
                outcomes.append(.finished(url))
            } catch {
                // An exporter may surface a cancel as some other error; the task's state decides.
                if error is CancellationError || Task.isCancelled {
                    outcomes.append(.cancelled)
                } else {
                    outcomes.append(.failed(error.localizedDescription))
                    tracker.complete(index: index)
                }
            }
        }
        return JobResult(outcomes: outcomes)
    }
}

/// Combines per-version progress into job progress. Versions are weighted by their
/// output length, since writing time grows with it. Reports can arrive on any thread,
/// so state sits behind a lock; reports from a version that already ended are dropped.
final class OverallProgress: Sendable {
    private struct State: Sendable {
        var completed: Set<Int> = []
        var lastFraction = 0.0
        var eta = ETAEstimator()
    }

    private let weights: [Double]
    private let total: Double
    private let start = ContinuousClock.now
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(weights: [Double]) {
        self.weights = weights
        total = max(weights.reduce(0, +), 1)
    }

    func complete(index: Int) {
        state.withLock { _ = $0.completed.insert(index) }
    }

    func report(index: Int, count: Int, version: ExportProgress) -> JobProgress {
        let elapsed = (ContinuousClock.now - start).timeInterval
        let done = weights.prefix(index).reduce(0, +)
        let current = state.withLock { $0.completed.contains(index) } ? 1 : version.fractionCompleted
        let raw = min(1, (done + weights[index] * current) / total)
        let (fraction, eta) = state.withLock { s -> (Double, TimeInterval?) in
            // Never go backwards (late reports from the exporter's own threads).
            s.lastFraction = max(s.lastFraction, raw)
            return (s.lastFraction, s.eta.update(fraction: s.lastFraction, elapsed: elapsed))
        }
        return JobProgress(versionIndex: index, versionCount: count, version: version,
                           overall: ExportProgress(fractionCompleted: fraction, estimatedTimeRemaining: eta))
    }
}
