import AVFoundation

/// One-call pipeline for milestone 1: load the clip, plan, write the loop (video only).
public enum LoopRenderer {
    @discardableResult
    public static func render(
        clipURL: URL,
        target: TargetDuration,
        to outputURL: URL,
        overwrite: Bool = false,
        progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws -> LoopPlan {
        let clip = try await ClipInfo.load(from: clipURL)
        let plan = LoopPlan(clip: clip, target: target)
        try await LoopWriter().export(clip: clip, plan: plan, to: outputURL, overwrite: overwrite, progress: progress)
        return plan
    }
}
