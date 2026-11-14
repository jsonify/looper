import AVFoundation

/// Why a clip can't be used as a loop source.
public enum ClipError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case noVideoTrack
    case multipleVideoTracks(Int)
    case emptyVideoTrack
    case notPlayable

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "The file couldn't be read: \(reason)"
        case .noVideoTrack: "The file has no video track."
        case .multipleVideoTracks(let count): "The file has \(count) video tracks; Looper needs exactly one."
        case .emptyVideoTrack: "The video track is empty."
        case .notPlayable: "macOS can't play this file."
        }
    }
}

/// Everything Looper needs to know about an input loop clip.
///
/// Times are kept as `CMTime` in the video track's own timescale so that hundreds of
/// back-to-back inserts stay frame exact (see CLAUDE.md, "Technical approach").
public struct ClipInfo: @unchecked Sendable {
    // @unchecked: all stored properties are immutable value types (CoreMedia/CoreGraphics
    // structs and Foundation values); some aren't annotated Sendable in every SDK.

    public let url: URL
    /// The video track's time range. Inserting this range (not the asset duration) is
    /// what keeps seams exact: the asset duration can include a longer audio track.
    public let videoTimeRange: CMTimeRange
    /// The video track's natural timescale, e.g. 15360 or 30000.
    public let timescale: CMTimeScale
    /// Duration of one frame (the track's minimum frame duration).
    public let frameDuration: CMTime
    public let nominalFrameRate: Float
    public let frameCount: Int
    public let naturalSize: CGSize
    public let preferredTransform: CGAffineTransform
    /// Codec as a four-character code, e.g. "avc1" or "hvc1".
    public let codec: String
    /// Average video bit rate in bits per second.
    public let estimatedDataRate: Float
    /// False when frame timing isn't uniform. Looping still works (inserts copy exact
    /// time ranges), but frame-count based figures become approximate.
    public let isConstantFrameRate: Bool
    /// Whether the clip has an audio track (offered as optional "Clip audio" in M3).
    public let hasAudio: Bool

    public var duration: CMTime { videoTimeRange.duration }

    /// Asset options used everywhere a clip is opened: precise timing makes AVFoundation
    /// read exact sample times instead of estimating them.
    static let assetOptions: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]

    /// Opens the clip and checks it has a single, non-empty, playable video track.
    public static func load(from url: URL) async throws -> ClipInfo {
        let asset = AVURLAsset(url: url, options: assetOptions)
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        let isPlayable: Bool
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            isPlayable = try await asset.load(.isPlayable)
        } catch {
            throw ClipError.unreadable(error.localizedDescription)
        }
        guard let track = videoTracks.first else { throw ClipError.noVideoTrack }
        guard videoTracks.count == 1 else { throw ClipError.multipleVideoTracks(videoTracks.count) }
        guard isPlayable else { throw ClipError.notPlayable }

        let (timeRange, timescale, minFrameDuration, nominalFrameRate) = try await track.load(
            .timeRange, .naturalTimeScale, .minFrameDuration, .nominalFrameRate)
        let (naturalSize, transform, formats, dataRate) = try await track.load(
            .naturalSize, .preferredTransform, .formatDescriptions, .estimatedDataRate)

        guard timeRange.duration.isValid, timeRange.duration > .zero else { throw ClipError.emptyVideoTrack }

        // Fall back to the nominal rate if the file doesn't report a minimum frame duration.
        var frameDuration = minFrameDuration
        if !frameDuration.isValid || frameDuration <= .zero {
            guard nominalFrameRate > 0 else { throw ClipError.emptyVideoTrack }
            frameDuration = CMTime(seconds: 1 / Double(nominalFrameRate), preferredTimescale: timescale)
        }

        let frameCount = Int((timeRange.duration.seconds / frameDuration.seconds).rounded())
        let isConstant = nominalFrameRate > 0
            && abs(Double(nominalFrameRate) * frameDuration.seconds - 1) < 0.01

        return ClipInfo(
            url: url,
            videoTimeRange: timeRange,
            timescale: timescale,
            frameDuration: frameDuration,
            nominalFrameRate: nominalFrameRate,
            frameCount: frameCount,
            naturalSize: naturalSize,
            preferredTransform: transform,
            codec: formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?",
            estimatedDataRate: dataRate,
            isConstantFrameRate: isConstant,
            hasAudio: !audioTracks.isEmpty)
    }
}

/// Renders a four-character code such as `kCMVideoCodecType_H264` as "avc1".
func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    return printable ? String(decoding: bytes, as: UTF8.self) : String(code)
}
