import AVFoundation

/// One-call pipeline for milestone 1: load the clip, plan, compose, export (video only).
public enum LoopRenderer {
    @discardableResult
    public static func render(
        clipURL: URL,
        target: TargetDuration,
        to outputURL: URL,
        overwrite: Bool = false,
        exporter: any CompositionExporter = PassthroughExporter(),
        progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws -> LoopPlan {
        let clip = try await ClipInfo.load(from: clipURL)
        let plan = LoopPlan(clip: clip, target: target)
        let loop = try await LoopComposer.compose(clip: clip, plan: plan)
        try await exporter.export(loop.composition, audioMix: nil, fileType: .mp4,
                                  to: outputURL, overwrite: overwrite, progress: progress)
        return plan
    }
}
