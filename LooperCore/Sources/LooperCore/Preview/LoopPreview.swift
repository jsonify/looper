import AVFoundation

/// The whole output as one playable timeline: the clip repeated to the target with the
/// audio laid on top, exactly as `LoopWriter` lays it out. Nothing is written to disk,
/// so even an 8 h preview is ready in a moment.
///
/// The audio mix (levels, fades) can be rebuilt on its own with `audioMix(for:)` and
/// swapped onto a playing item, so volume changes are heard live.
public final class LoopPreview: @unchecked Sendable {
    // @unchecked: everything is built once in `build` and only read afterwards.

    /// An immutable copy of the composition, as AVPlayer prefers.
    public let composition: AVComposition
    public let timeline: PreviewTimeline
    let mixes: [AudioTrackMix]
    /// Source files, held so their tracks stay readable while the preview plays.
    private let sourceAssets: [AVAsset]

    private init(composition: AVComposition, timeline: PreviewTimeline, mixes: [AudioTrackMix], sourceAssets: [AVAsset]) {
        self.composition = composition
        self.timeline = timeline
        self.mixes = mixes
        self.sourceAssets = sourceAssets
    }

    public static func build(clip: ClipInfo, plan: LoopPlan, audio: LoopAudioSettings) async throws -> LoopPreview {
        // The same composition the drift tests check: frame-exact inserts of the clip.
        let loop = try await LoopComposer.compose(clip: clip, plan: plan)
        var mixes: [AudioTrackMix] = []
        var sourceAssets: [AVAsset] = []
        if audio.hasAudio(clipHasAudio: clip.hasAudio),
           let loopAudio = try await LoopAudioBuilder.build(settings: audio, clip: clip, plan: plan, into: loop.composition) {
            mixes = loopAudio.mixes
            sourceAssets = loopAudio.sourceAssets
        }
        let timeline = PreviewTimeline(plan: plan, lanes: lanes(for: mixes))
        guard let composition = loop.composition.copy() as? AVComposition else {
            throw LoopComposerError.cannotAddTrack
        }
        return LoopPreview(composition: composition, timeline: timeline, mixes: mixes, sourceAssets: sourceAssets)
    }

    /// The volume ramps for `settings`; a role missing from it is silent.
    public func audioMix(for settings: [AudioRole: AudioTrackSettings]) -> AVAudioMix? {
        guard !mixes.isEmpty else { return nil }
        return LoopAudioBuilder.audioMix(for: mixes, total: timeline.duration) { settings[$0] }
    }

    /// The audio tracks of each role merged into one lane (a chain uses two tracks).
    static func lanes(for mixes: [AudioTrackMix]) -> [PreviewTimeline.Lane] {
        AudioRole.allCases.compactMap { role in
            let pieces = mixes.filter { $0.role == role }.flatMap { mix in
                mix.placements.map { p in
                    PreviewTimeline.Piece(title: mix.itemNames.indices.contains(p.itemIndex) ? mix.itemNames[p.itemIndex] : "",
                                          start: p.start, length: p.length, fadeIn: p.fadeIn, fadeOut: p.fadeOut, track: p.track)
                }
            }
            return pieces.isEmpty ? nil : PreviewTimeline.Lane(role: role, pieces: pieces)
        }
    }
}
