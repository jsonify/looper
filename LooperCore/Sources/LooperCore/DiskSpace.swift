import Foundation

/// Output size estimate for a plan. Passthrough copies samples, so the output is the
/// clip's video bytes scaled by the number of frames, plus a little container index.
public enum OutputEstimate {
    /// Bytes per frame for the MP4 sample tables (sizes, timestamps, offsets).
    static let indexBytesPerFrame: Double = 16

    public static func bytes(clip: ClipInfo, plan: LoopPlan) -> Int64 {
        guard clip.frameCount > 0 else { return 0 }
        let perFrame = Double(clip.videoByteCount) / Double(clip.frameCount)
        return Int64((perFrame + indexBytesPerFrame) * Double(plan.frameCount))
    }
}

/// Whether an export fits on the destination volume (and within YouTube's limit).
public struct SpaceCheck: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        /// Plenty of room.
        case ok
        /// Fits, but leaves the disk nearly full: warn.
        case low
        /// Doesn't fit: block the export.
        case insufficient
    }

    public let level: Level
    public let estimatedBytes: Int64
    /// nil when the volume couldn't be queried; then only the YouTube limit is checked.
    public let availableBytes: Int64?
    public let exceedsYouTubeLimit: Bool

    /// YouTube's upload size limit (256 GB).
    public static let youTubeLimitBytes: Int64 = 256_000_000_000
    /// Headroom wanted after the export: 10 % of its size, at least 2 GB.
    static func margin(for estimate: Int64) -> Int64 { max(estimate / 10, 2_000_000_000) }

    public static func evaluate(estimatedBytes: Int64, availableBytes: Int64?) -> SpaceCheck {
        let level: Level
        if let available = availableBytes {
            if estimatedBytes > available {
                level = .insufficient
            } else if estimatedBytes + margin(for: estimatedBytes) > available {
                level = .low
            } else {
                level = .ok
            }
        } else {
            level = .ok
        }
        return SpaceCheck(level: level, estimatedBytes: estimatedBytes, availableBytes: availableBytes,
                          exceedsYouTubeLimit: estimatedBytes > youTubeLimitBytes)
    }

    /// A sentence for the UI, or nil when there's nothing to say.
    public var message: String? {
        let size = ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
        let free = availableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
        var lines: [String] = []
        switch level {
        case .insufficient: lines.append("Not enough space: the video needs about \(size), but only \(free) is free.")
        case .low: lines.append("The disk will be nearly full: the video needs about \(size) and \(free) is free.")
        case .ok: break
        }
        if exceedsYouTubeLimit {
            lines.append("About \(size) is over YouTube's 256 GB upload limit.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

public enum DiskSpace {
    /// Free space for the volume holding `url` (or its nearest existing parent, since
    /// the output folders are created at export time). Uses the "important usage"
    /// figure, which counts space macOS can free up, like Finder does.
    public static func availableBytes(for url: URL) -> Int64? {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
