import AVFoundation

/// A long timeline built by repeating a clip back to back.
///
/// Holds the `AVMutableComposition` plus the bookkeeping later stages need: audio (M3)
/// is laid onto the same composition and aligned to `insertTimes`.
public struct LoopComposition {
    public let composition: AVMutableComposition
    public let videoTrack: AVMutableCompositionTrack
    public let plan: LoopPlan
    /// Start time of each copy, in output order.
    public let insertTimes: [CMTime]
}

public enum LoopComposerError: Error, LocalizedError {
    case cannotAddTrack

    public var errorDescription: String? { "Couldn't create the composition's video track." }
}

public enum LoopComposer {
    /// Builds the composition: `plan.fullCopies` copies of the clip's video time range,
    /// then the trimmed last copy, with no gaps or overlaps.
    public static func compose(clip: ClipInfo, plan: LoopPlan) async throws -> LoopComposition {
        let asset = AVURLAsset(url: clip.url, options: ClipInfo.assetOptions)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipError.noVideoTrack
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LoopComposerError.cannotAddTrack
        }
        // Keep the clip's orientation (e.g. a portrait clip recorded rotated).
        track.preferredTransform = clip.preferredTransform

        // Insert the video track's own time range, and advance the cursor by adding exact
        // CMTimes in the track's timescale. Using the asset duration or Double seconds
        // here would let tiny rounding errors accumulate into dropped or repeated frames
        // after hundreds of copies.
        let insertTimes = plan.insertTimes
        for (index, start) in insertTimes.enumerated() {
            let isTrimmedCopy = index == plan.fullCopies
            let range = isTrimmedCopy
                ? CMTimeRange(start: clip.videoTimeRange.start, duration: plan.remainder)
                : clip.videoTimeRange
            try track.insertTimeRange(range, of: sourceTrack, at: start)
        }

        return LoopComposition(composition: composition, videoTrack: track, plan: plan, insertTimes: insertTimes)
    }
}
