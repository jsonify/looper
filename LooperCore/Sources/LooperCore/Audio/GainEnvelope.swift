import Foundation

/// Volume over time for one composition track, as points joined by linear ramps (the
/// form `AVMutableAudioMixInputParameters` accepts).
///
/// The gain is track volume × the track's fade in/out at the start and end of the video
/// × each piece's crossfade weight. Crossfades use equal-power curves (sine in, cosine
/// out), approximated by several short linear ramps, so overlapping uncorrelated audio
/// (a bed wrapping onto a different part of itself, two different songs) keeps a steady
/// loudness instead of dipping in the middle like a linear crossfade does.
public enum GainEnvelope {
    public struct Point: Equatable, Sendable {
        public let time: Double
        public let gain: Float
    }

    /// Linear ramps per curved stretch; 8 keeps the equal-power error under ~1 %.
    public static let stepsPerCurve = 8
    /// Fades up to this long (seconds) get a single linear ramp.
    public static let shortFade = 0.05

    /// Built piece by piece, so the cost grows linearly with the number of pieces
    /// (an 8 h playlist of short songs has thousands).
    public static func points(
        for placements: [AudioPlacement], volume: Float, fadeIn: Double, fadeOut: Double, total: Double
    ) -> [Point] {
        let pieces = placements.sorted { $0.start < $1.start }
        guard let first = pieces.first else { return [] }
        func curve(_ from: Double, _ length: Double) -> [Double] {
            guard length > 0 else { return [] }
            // A click guard (clip audio's 10 ms edge fades) is too short for its shape to
            // be heard: one ramp, not eight. Ramps are costly in bulk (see `BedLoop`).
            if length <= shortFade { return [from, from + length] }
            return (0...stepsPerCurve).map { from + length * Double($0) / Double(stepsPerCurve) }
        }
        // Track fade in/out points: few, so each piece just filters them.
        let trackFadeTimes = curve(0, min(fadeIn, total)) + curve(max(total - fadeOut, 0), min(fadeOut, total))

        var result: [Point] = []
        if first.start > 0 { result.append(Point(time: 0, gain: 0)) }
        for piece in pieces {
            var times = [piece.start, piece.end]
                + curve(piece.start, piece.fadeIn)
                + curve(piece.end - piece.fadeOut, piece.fadeOut)
                + trackFadeTimes.filter { $0 > piece.start && $0 < piece.end }
            times = times.filter { $0 >= 0 && $0 <= total }.sorted()
            for t in times where result.last.map({ t - $0.time > 1e-6 }) ?? true {
                result.append(Point(time: t, gain: gain(at: t, in: piece, volume: volume,
                                                        fadeIn: fadeIn, fadeOut: fadeOut, total: total)))
            }
        }
        return result
    }

    /// Gain at `t` on a track, looking up which piece is playing (0 between pieces).
    static func gain(at t: Double, placements: [AudioPlacement], volume: Float,
                     fadeIn: Double, fadeOut: Double, total: Double) -> Float {
        // The piece playing at t on this track (pieces on one track never overlap).
        guard let piece = placements.first(where: { t >= $0.start - 1e-9 && t <= $0.end + 1e-9 }) else { return 0 }
        return gain(at: t, in: piece, volume: volume, fadeIn: fadeIn, fadeOut: fadeOut, total: total)
    }

    /// Gain at `t` within `piece`: volume × crossfade weight × track fade.
    static func gain(at t: Double, in p: AudioPlacement, volume: Float,
                     fadeIn: Double, fadeOut: Double, total: Double) -> Float {
        var weight = 1.0
        if p.fadeIn > 0, t < p.start + p.fadeIn { weight *= fadeInCurve((t - p.start) / p.fadeIn) }
        if p.fadeOut > 0, t > p.end - p.fadeOut { weight *= fadeOutCurve((t - (p.end - p.fadeOut)) / p.fadeOut) }
        if fadeIn > 0, t < fadeIn { weight *= fadeInCurve(t / fadeIn) }
        if fadeOut > 0, t > total - fadeOut { weight *= fadeOutCurve((t - (total - fadeOut)) / fadeOut) }
        return Float(weight) * volume
    }

    static func fadeInCurve(_ x: Double) -> Double { sin(min(max(x, 0), 1) * .pi / 2) }
    static func fadeOutCurve(_ x: Double) -> Double { cos(min(max(x, 0), 1) * .pi / 2) }
}
