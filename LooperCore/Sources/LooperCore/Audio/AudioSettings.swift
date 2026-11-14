import Foundation

/// Level and fades for one audio track.
public struct AudioTrackSettings: Codable, Equatable, Sendable {
    /// Linear gain, 0...1.
    public var volume: Float
    /// Fade in at the start of the video, seconds.
    public var fadeIn: Double
    /// Fade out at the end of the video, seconds.
    public var fadeOut: Double

    public init(volume: Float, fadeIn: Double, fadeOut: Double) {
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }
}

/// The ambient bed: one file looped for the whole video.
public struct BedSettings: Codable, Equatable, Sendable {
    public var file: URL
    public var track: AudioTrackSettings
    /// Overlap where the bed wraps around to its start, seconds.
    public var wrapCrossfade: Double

    public static let defaultTrack = AudioTrackSettings(volume: 0.6, fadeIn: 5, fadeOut: 10)
    public static let defaultWrapCrossfade = 3.0

    public init(file: URL, track: AudioTrackSettings = defaultTrack, wrapCrossfade: Double = defaultWrapCrossfade) {
        self.file = file
        self.track = track
        self.wrapCrossfade = wrapCrossfade
    }
}

/// The music playlist: a folder of songs chained in name order, cycling to fill the video.
public struct PlaylistSettings: Codable, Equatable, Sendable {
    public var folder: URL
    public var track: AudioTrackSettings
    /// Overlap between consecutive songs, seconds (0 = back to back).
    public var crossfade: Double

    public static let defaultTrack = AudioTrackSettings(volume: 0.8, fadeIn: 3, fadeOut: 10)
    public static let defaultCrossfade = 3.0

    public init(folder: URL, track: AudioTrackSettings = defaultTrack, crossfade: Double = defaultCrossfade) {
        self.folder = folder
        self.track = track
        self.crossfade = crossfade
    }
}

/// The clip's own audio track, repeated with each copy of the video. Off by default: a
/// 30 s audio loop repeats audibly and generated audio rarely loops seamlessly.
public struct ClipAudioSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var track: AudioTrackSettings

    public static let defaultTrack = AudioTrackSettings(volume: 0.5, fadeIn: 3, fadeOut: 10)

    public init(enabled: Bool = false, track: AudioTrackSettings = defaultTrack) {
        self.enabled = enabled
        self.track = track
    }
}

/// Everything about the audio of one export. Codable so M4 presets can store it.
public struct LoopAudioSettings: Codable, Equatable, Sendable {
    public var bed: BedSettings?
    public var playlist: PlaylistSettings?
    public var clipAudio: ClipAudioSettings

    public init(bed: BedSettings? = nil, playlist: PlaylistSettings? = nil, clipAudio: ClipAudioSettings = ClipAudioSettings()) {
        self.bed = bed
        self.playlist = playlist
        self.clipAudio = clipAudio
    }

    /// True when the output would have an audio track (given whether the clip has audio).
    public func hasAudio(clipHasAudio: Bool) -> Bool {
        bed != nil || playlist != nil || (clipAudio.enabled && clipHasAudio)
    }

    /// Output audio: AAC, 48 kHz, stereo.
    public static let sampleRate = 48_000.0
    public static let bitRate = 256_000
}
