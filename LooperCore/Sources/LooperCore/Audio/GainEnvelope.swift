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

    public static func points(
        for placements: [AudioPlacement], volume: Float, fadeIn: Double, fadeOut: Double, total: Double
    ) -> [Point] {
        guard !placements.isEmpty else { return [] }
        var times: [Double] = [0, total]
        func curve(_ from: Double, _ length: Double) {
            guard length > 0 else { return }
            for step in 0...stepsPerCurve { times.append(from + length * Double(step) / Double(stepsPerCurve)) }
        }
        for p in placements {
            times += [p.start, p.end]
            curve(p.start, p.fadeIn)
            curve(p.end - p.fadeOut, p.fadeOut)
        }
        curve(0, min(fadeIn, total))
        curve(max(total - fadeOut, 0), min(fadeOut, total))

        let sorted = times.filter { $0 >= 0 && $0 <= total }.sorted()
        var unique: [Double] = []
        for t in sorted where unique.last.map({ t - $0 > 1e-6 }) ?? true { unique.append(t) }
        return unique.map { Point(time: $0, gain: gain(at: $0, placements: placements, volume: volume,
                                                      fadeIn: fadeIn, fadeOut: fadeOut, total: total)) }
    }

    static func gain(at t: Double, placements: [AudioPlacement], volume: Float,
                     fadeIn: Double, fadeOut: Double, total: Double) -> Float {
        // The piece playing at t on this track (pieces on one track never overlap).
        guard let p = placements.first(where: { t >= $0.start - 1e-9 && t <= $0.end + 1e-9 }) else { return 0 }
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
