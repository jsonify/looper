import CoreMedia
import Foundation

/// A requested output length in whole seconds: a preset (1 h, 3 h, 8 h) or custom h:mm:ss.
public struct TargetDuration: Hashable, Sendable, CustomStringConvertible {
    public let seconds: Int

    /// YouTube's maximum video length.
    public static let maximumSeconds = 12 * 3600

    public static let oneHour = TargetDuration(validSeconds: 3600)
    public static let threeHours = TargetDuration(validSeconds: 3 * 3600)
    public static let eightHours = TargetDuration(validSeconds: 8 * 3600)
    public static let presets: [TargetDuration] = [oneHour, threeHours, eightHours]

    private init(validSeconds: Int) { seconds = validSeconds }

    public init(seconds: Int) throws {
        guard seconds > 0 else { throw TargetDurationError.zero }
        guard seconds <= Self.maximumSeconds else { throw TargetDurationError.tooLong(seconds) }
        self.seconds = seconds
    }

    public init(hours: Int = 0, minutes: Int = 0, seconds: Int = 0) throws {
        try self.init(seconds: hours * 3600 + minutes * 60 + seconds)
    }

    /// Parses "h:mm:ss", "m:ss", "8h" or "45m". Minutes and seconds after a colon must be
    /// below 60.
    public init(parsing text: String) throws {
        let input = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let unit = input.last, unit == "h" || unit == "m",
           let value = Int(input.dropLast()), value >= 0 {
            try self.init(seconds: value * (unit == "h" ? 3600 : 60))
            return
        }
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let n = Int(part), n >= 0 else { return nil }
            return n
        }
        guard (2...3).contains(parts.count), numbers.count == parts.count,
              numbers.dropFirst().allSatisfy({ $0 < 60 }) else {
            throw TargetDurationError.malformed(text)
        }
        let total = numbers.reduce(0) { $0 * 60 + $1 }
        try self.init(seconds: total)
    }

    public var cmTime: CMTime { CMTime(value: CMTimeValue(seconds), timescale: 1) }

    /// "8:00:00", "1:00:10".
    public var description: String {
        String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

public enum TargetDurationError: Error, Equatable, LocalizedError {
    case malformed(String)
    case zero
    case tooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .malformed(let text): "“\(text)” isn't a duration. Use h:mm:ss, for example 1:00:10."
        case .zero: "The duration must be longer than zero."
        case .tooLong: "YouTube accepts videos up to 12 hours."
        }
    }
}

/// How a clip is repeated to reach a target duration: some full copies, then one
/// trimmed copy.
///
/// The target is rounded down to a whole number of frames, so a 29.97 fps clip asked to
/// fill 1 h ends on the last whole frame before 1 h. All math is integer frame counts
/// and exact `CMTime`s, never floating-point seconds, so nothing drifts over 960 copies.
public struct LoopPlan: Equatable, @unchecked Sendable {
    // @unchecked: stored CMTimes are plain value types.

    /// Duration of one full copy (the clip's video time range).
    public let clipDuration: CMTime
    public let frameDuration: CMTime
    public let clipFrameCount: Int
    /// Total output frames.
    public let frameCount: Int
    public let fullCopies: Int
    /// Frames in the trimmed last copy; 0 when the target is a whole number of copies.
    public let remainderFrames: Int
    /// Duration of the trimmed last copy (zero if none).
    public let remainder: CMTime
    /// Exact output duration.
    public let duration: CMTime

    public var copyCount: Int { fullCopies + (remainderFrames > 0 ? 1 : 0) }

    /// Start time of every copy in the output, in order.
    public var insertTimes: [CMTime] {
        (0..<copyCount).map { clipDuration.multiplied(by: $0) }
    }

    public init(clip: ClipInfo, target: TargetDuration) {
        self.init(clipDuration: clip.duration, frameDuration: clip.frameDuration,
                  clipFrameCount: clip.frameCount, target: target)
    }

    /// - Parameters:
    ///   - clipDuration: the clip's video time range duration; equal to
    ///     `clipFrameCount × frameDuration` for constant frame rate clips.
    public init(clipDuration: CMTime, frameDuration: CMTime, clipFrameCount: Int, target: TargetDuration) {
        precondition(clipFrameCount > 0 && frameDuration > .zero, "clip must have frames")
        self.clipDuration = clipDuration
        self.frameDuration = frameDuration
        self.clipFrameCount = clipFrameCount

        // Whole frames that fit in the target: floor(seconds × timescale / value).
        let totalFrames = Int(Int64(target.seconds) * Int64(frameDuration.timescale) / frameDuration.value)
        frameCount = totalFrames
        fullCopies = totalFrames / clipFrameCount
        remainderFrames = totalFrames % clipFrameCount
        // Keep the remainder in the clip's timescale where possible, so the composition
        // works in one timescale throughout.
        let rawRemainder = frameDuration.multiplied(by: remainderFrames)
        remainder = CMTimeConvertScale(rawRemainder, timescale: clipDuration.timescale, method: .roundHalfAwayFromZero)
        duration = clipDuration.multiplied(by: fullCopies) + remainder
    }
}

extension CMTime {
    /// Exact multiplication (CoreMedia has no `*` operator for CMTime and an integer).
    func multiplied(by count: Int) -> CMTime {
        CMTimeMultiply(self, multiplier: Int32(count))
    }
}
