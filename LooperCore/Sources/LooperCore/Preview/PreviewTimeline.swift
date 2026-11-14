import Foundation

/// What the preview's timeline shows: where the clip's seams fall, and what each audio
/// part plays when. Also finds the places worth listening to (seams, bed wraps, song
/// changes, the final fade), so the user doesn't have to scrub through hours.
///
/// Plain values, no AVFoundation, so it can be tested and drawn directly.
public struct PreviewTimeline: Equatable, Sendable {
    /// One piece of audio on a lane, e.g. one song or one pass of the bed.
    public struct Piece: Equatable, Sendable {
        public let title: String
        public let start: Double
        public let length: Double
        /// Crossfade with the previous and next piece, seconds.
        public let fadeIn: Double
        public let fadeOut: Double
        /// Composition track (0 or 1) the piece plays on.
        public let track: Int

        public var end: Double { start + length }

        public init(title: String, start: Double, length: Double, fadeIn: Double = 0, fadeOut: Double = 0, track: Int = 0) {
            self.title = title
            self.start = start
            self.length = length
            self.fadeIn = fadeIn
            self.fadeOut = fadeOut
            self.track = track
        }
    }

    public struct Lane: Equatable, Sendable {
        public let role: AudioRole
        /// In start order.
        public let pieces: [Piece]

        public init(role: AudioRole, pieces: [Piece]) {
            self.role = role
            self.pieces = pieces.sorted { $0.start < $1.start }
        }
    }

    public enum Jump: CaseIterable, Sendable {
        case start, nextSeam, nextBedWrap, nextSongChange, finalFade
    }

    /// Output length, seconds.
    public let duration: Double
    /// Length of one full copy of the clip; seams are at its multiples.
    public let clipDuration: Double
    public let frameDuration: Double
    public let copyCount: Int
    /// Audio lanes in display order (bed, playlist, clip audio), only those in use.
    public let lanes: [Lane]

    /// A jump lands this many seconds before the spot, so you hear into it.
    public static let jumpLead = 3.0

    public init(duration: Double, clipDuration: Double, frameDuration: Double, copyCount: Int, lanes: [Lane]) {
        self.duration = duration
        self.clipDuration = clipDuration
        self.frameDuration = frameDuration
        self.copyCount = copyCount
        self.lanes = AudioRole.allCases.compactMap { role in lanes.first { $0.role == role } }
    }

    public init(plan: LoopPlan, lanes: [Lane]) {
        self.init(duration: plan.duration.seconds, clipDuration: plan.clipDuration.seconds,
                  frameDuration: plan.frameDuration.seconds, copyCount: plan.copyCount, lanes: lanes)
    }

    public func lane(_ role: AudioRole) -> Lane? { lanes.first { $0.role == role } }

    /// Where the bed starts over (after the first pass).
    public var bedWraps: [Double] { lane(.bed)?.pieces.dropFirst().map(\.start) ?? [] }
    /// Where each song after the first starts.
    public var songChanges: [Double] { lane(.playlist)?.pieces.dropFirst().map(\.start) ?? [] }

    /// Which copy (1-based) and which frame of the clip (0-based) show at `time`.
    public func position(at time: Double) -> (copy: Int, frame: Int) {
        guard clipDuration > 0, frameDuration > 0 else { return (1, 0) }
        let t = min(max(time, 0), duration)
        // A small epsilon so a time exactly on a frame boundary isn't floored to the frame before.
        let copy = min(Int((t + 1e-6) / clipDuration), copyCount - 1)
        let frame = Int(((t - Double(copy) * clipDuration) + 1e-6) / frameDuration)
        return (copy + 1, frame)
    }

    /// Where `jump` goes from `time`, or nil when there's no such spot after it.
    /// - Parameter finalFade: length of the longest fade out at the end, seconds.
    public func time(for jump: Jump, from time: Double, finalFade: Double = 10) -> Double? {
        let lead = Self.jumpLead
        // Skip a spot the playhead is already sitting just before, so pressing the
        // button again moves on to the next one.
        func next(after spots: [Double]) -> Double? {
            spots.first { $0 - lead > time + 0.25 }.map { max(0, $0 - lead) }
        }
        switch jump {
        case .start:
            return 0
        case .nextSeam:
            guard copyCount > 1, clipDuration > 0 else { return nil }
            let k = Int(((time + lead + 0.25) / clipDuration).rounded(.down)) + 1
            return k < copyCount ? max(0, Double(k) * clipDuration - lead) : nil
        case .nextBedWrap:
            return next(after: bedWraps)
        case .nextSongChange:
            return next(after: songChanges)
        case .finalFade:
            return max(0, duration - max(finalFade, 0) - lead)
        }
    }

    /// How loud `role` plays at `time`, 0...1, for drawing its level line: volume ×
    /// fades, with the two sides of a crossfade added by power (equal-power crossfades
    /// keep a steady loudness, so the line stays flat through them).
    public func level(_ role: AudioRole, at time: Double, settings: AudioTrackSettings) -> Float {
        guard let lane = lane(role) else { return 0 }
        var power: Float = 0
        for piece in lane.pieces where time >= piece.start - 1e-9 && time <= piece.end + 1e-9 {
            let placement = AudioPlacement(itemIndex: 0, start: piece.start, length: piece.length, track: piece.track,
                                           fadeIn: piece.fadeIn, fadeOut: piece.fadeOut)
            let g = GainEnvelope.gain(at: time, in: placement, volume: settings.volume,
                                      fadeIn: settings.fadeIn, fadeOut: settings.fadeOut, total: duration)
            power += g * g
        }
        return min(power.squareRoot(), 1)
    }
}
