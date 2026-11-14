import AVFoundation

/// Progress of a running export.
public struct ExportProgress: Sendable, Equatable {
    /// 0...1.
    public let fractionCompleted: Double
    /// Seconds left, or nil while there isn't enough data for an honest estimate.
    public let estimatedTimeRemaining: TimeInterval?

    public init(fractionCompleted: Double, estimatedTimeRemaining: TimeInterval?) {
        self.fractionCompleted = fractionCompleted
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }
}

public enum ExportError: Error, Equatable, LocalizedError {
    case outputExists(URL)
    case incompatible(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .outputExists(let url): "\(url.lastPathComponent) already exists."
        case .incompatible(let reason): "This clip can't be exported this way: \(reason)"
        case .failed(let reason): "Export failed: \(reason)"
        }
    }
}

/// Writes a composition to a file. The passthrough exporter is the default; a reader/
/// writer exporter can replace it (for example if audio mixing needs it, see M3)
/// without callers changing.
public protocol CompositionExporter: Sendable {
    /// Exports `asset` to `outputURL`. Writes to a temporary file next to the output and
    /// renames it on success, so a cancelled or failed export never leaves a partial
    /// `video.mp4` behind. Throws `CancellationError` when the task is cancelled.
    func export(
        _ asset: AVAsset,
        audioMix: AVAudioMix?,
        fileType: AVFileType,
        to outputURL: URL,
        overwrite: Bool,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws
}

extension CompositionExporter {
    public func export(
        _ asset: AVAsset,
        to outputURL: URL,
        overwrite: Bool = false,
        progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws {
        try await export(asset, audioMix: nil, fileType: .mp4, to: outputURL,
                         overwrite: overwrite, progress: progress)
    }
}

/// Exports with `AVAssetExportPresetPassthrough`: video samples are copied, not
/// re-encoded, so an 8 h export is a large file copy rather than an 8 h encode.
public struct PassthroughExporter: CompositionExporter {
    /// How often progress is reported.
    public var progressInterval: Duration = .milliseconds(250)

    public init() {}

    public func export(
        _ asset: AVAsset,
        audioMix: AVAudioMix?,
        fileType: AVFileType,
        to outputURL: URL,
        overwrite: Bool,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        let files = FileManager.default
        if files.fileExists(atPath: outputURL.path) {
            guard overwrite else { throw ExportError.outputExists(outputURL) }
            try files.removeItem(at: outputURL)
        }
        let partialURL = Self.partialURL(for: outputURL)
        try? files.removeItem(at: partialURL)

        let preset = AVAssetExportPresetPassthrough
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ExportError.incompatible("passthrough to \(fileType.rawValue) isn't supported")
        }
        session.outputURL = partialURL
        session.outputFileType = fileType
        session.audioMix = audioMix
        // Moving the movie header to the front would cost a second pass over a file that
        // can be tens of GB; YouTube doesn't need it for uploads.
        session.shouldOptimizeForNetworkUse = false

        let box = SessionBox(session)
        let interval = progressInterval
        let reporter = Task {
            var eta = ETAEstimator()
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                let fraction = Double(box.session.progress)
                let elapsed = (clock.now - start).timeInterval
                progress(ExportProgress(fractionCompleted: fraction,
                                        estimatedTimeRemaining: eta.update(fraction: fraction, elapsed: elapsed)))
                try? await Task.sleep(for: interval)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        // Stop progress reports before the final one, so nothing stale arrives after 100%.
        reporter.cancel()
        await reporter.value

        switch box.session.status {
        case .completed:
            try files.moveItem(at: partialURL, to: outputURL)
            progress(ExportProgress(fractionCompleted: 1, estimatedTimeRemaining: 0))
        case .cancelled:
            try? files.removeItem(at: partialURL)
            throw CancellationError()
        default:
            try? files.removeItem(at: partialURL)
            if Task.isCancelled { throw CancellationError() }
            throw ExportError.failed(box.session.error?.localizedDescription ?? "unknown error")
        }
    }

    /// Hidden temporary file in the output folder (same volume, so the final rename is
    /// instant), e.g. `.video.partial.mp4`.
    static func partialURL(for outputURL: URL) -> URL {
        let name = "." + outputURL.deletingPathExtension().lastPathComponent + ".partial." + outputURL.pathExtension
        return outputURL.deletingLastPathComponent().appendingPathComponent(name)
    }
}

/// Lets the progress task and the cancellation handler share the session. Safe because
/// AVAssetExportSession's progress, status and cancelExport are documented as callable
/// from any thread while an export runs.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

/// Estimates time remaining from the average rate since the start. The average rate is
/// stable for passthrough exports (roughly constant throughput), and it's hidden until
/// there's enough progress for the number to mean something.
public struct ETAEstimator: Sendable {
    public var minimumFraction = 0.02
    public var minimumElapsed: TimeInterval = 1.5

    public init() {}

    public mutating func update(fraction: Double, elapsed: TimeInterval) -> TimeInterval? {
        if fraction >= 1 { return 0 }
        guard fraction >= minimumFraction, elapsed >= minimumElapsed else { return nil }
        return elapsed * (1 - fraction) / fraction
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
