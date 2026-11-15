import AVFoundation

/// An audio-only timeline for one export plus the mix (levels, fades, crossfades) to
/// render it with. Mixed down to one AAC track by `LoopWriter`.
struct LoopAudio {
    let composition: AVMutableComposition
    let audioMix: AVAudioMix
    let tracks: [AVMutableCompositionTrack]
    /// What each track plays, so the mix can be rebuilt with other levels and fades
    /// (the preview does this live) without rebuilding the timeline.
    let mixes: [AudioTrackMix]
    /// The source files. An AVAssetTrack doesn't keep its asset alive, so the assets
    /// are held here for as long as the composition is read.
    let sourceAssets: [AVAsset]
}

/// Which part of the audio a composition track belongs to.
public enum AudioRole: String, CaseIterable, Hashable, Sendable {
    case bed, playlist, clipAudio
}

/// One audio composition track: its role, what plays on it and when.
struct AudioTrackMix: Sendable {
    let trackID: CMPersistentTrackID
    let role: AudioRole
    let placements: [AudioPlacement]
    /// Names of the items `placements` index into (song file names for the playlist).
    let itemNames: [String]
    /// What the volume ramps follow. Usually `placements`; a rendered bed (`BedLoop`)
    /// shows its wraps in `placements` but has them baked in, so it is one piece here.
    let gainPlacements: [AudioPlacement]

    init(trackID: CMPersistentTrackID, role: AudioRole, placements: [AudioPlacement], itemNames: [String],
         gainPlacements: [AudioPlacement]? = nil) {
        self.trackID = trackID
        self.role = role
        self.placements = placements
        self.itemNames = itemNames
        self.gainPlacements = gainPlacements ?? placements
    }
}

extension LoopAudioSettings {
    /// Level and fades of `role`, or nil when that part isn't used.
    public func track(for role: AudioRole) -> AudioTrackSettings? {
        switch role {
        case .bed: bed?.track
        case .playlist: playlist?.track
        case .clipAudio: clipAudio.enabled ? clipAudio.track : nil
        }
    }
}

/// Builds the audio timeline: the bed and playlist chained with crossfades on
/// alternating track pairs, and the clip's own audio aligned with each video copy.
enum LoopAudioBuilder {
    /// Timescale for audio placements: one unit per sample at 48 kHz.
    static let timescale: CMTimeScale = 48_000

    /// Short fades at each copy edge of clip audio, so the tiny gaps where an AAC track
    /// is a few ms shorter than the video don't click.
    static let clipAudioEdgeFade = 0.01

    /// - Parameter composition: where to add the audio tracks; a new composition when
    ///   nil. The preview passes the looped video's composition so one player item
    ///   plays both.
    static func build(settings: LoopAudioSettings, clip: ClipInfo, plan: LoopPlan,
                      into composition: AVMutableComposition = AVMutableComposition()) async throws -> LoopAudio? {
        let total = plan.duration.seconds
        var tracks: [AVMutableCompositionTrack] = []
        var mixes: [AudioTrackMix] = []
        var sourceAssets: [AVAsset] = []

        func addChain(items: [AudioItem], crossfade: Double, role: AudioRole) async throws {
            let placements = AudioChain.placements(itemDurations: items.map(\.seconds), crossfade: crossfade, fill: total)
            let sources = try await items.asyncMap { try await sourceTrack(for: $0.url) }
            sourceAssets += sources.map(\.asset)
            for trackIndex in 0..<2 {
                let onTrack = placements.filter { $0.track == trackIndex }
                guard !onTrack.isEmpty else { continue }
                let track = try addTrack(to: composition)
                for p in onTrack {
                    let source = sources[p.itemIndex]
                    // A trimmed item (a bed with its silent lead-in removed) starts part way in.
                    let from = source.start + time(items[p.itemIndex].start)
                    try insert(source.track, from: from, length: p.length, at: p.start, into: track)
                }
                tracks.append(track)
                mixes.append(AudioTrackMix(trackID: track.trackID, role: role, placements: onTrack,
                                           itemNames: items.map(\.name)))
            }
        }

        /// A short bed repeats many times: render it once with the wrap crossfade baked
        /// in and repeat that on one track, so the mix needs no ramps per wrap.
        func addRenderedBed(_ item: AudioItem, crossfade: Double) async throws {
            let overlap = BedLoop.overlap(itemSeconds: item.seconds, crossfade: crossfade)
            let loop = try await BedLoop.render(item: item, overlapSeconds: overlap)
            let source = try await sourceTrack(for: loop.url)
            sourceAssets.append(source.asset)
            let track = try addTrack(to: composition)
            for segment in loop.segments(totalFrames: time(total).value) {
                try track.insertTimeRange(
                    CMTimeRange(start: source.start + CMTime(value: segment.from, timescale: timescale),
                                duration: CMTime(value: segment.length, timescale: timescale)),
                    of: source.track, at: CMTime(value: segment.at, timescale: timescale))
            }
            tracks.append(track)
            // The timeline still shows each wrap where the chain would put it.
            let shown = AudioChain.placements(itemDurations: [item.seconds], crossfade: crossfade, fill: total)
            let whole = AudioPlacement(itemIndex: 0, start: 0, length: total, track: 0, fadeIn: 0, fadeOut: 0)
            mixes.append(AudioTrackMix(trackID: track.trackID, role: .bed, placements: shown,
                                       itemNames: [item.name], gainPlacements: [whole]))
        }

        if let bed = settings.bed {
            let item = try await AudioItem.load(from: bed.file).trimmed(bed.trim)
            if item.seconds <= BedLoop.maxRenderedSeconds, item.seconds < total {
                try await addRenderedBed(item, crossfade: bed.wrapCrossfade)
            } else {
                try await addChain(items: [item], crossfade: bed.wrapCrossfade, role: .bed)
            }
        }
        if let playlist = settings.playlist {
            let items = try await FolderAudioSource(folder: playlist.folder).items()
            try await addChain(items: items, crossfade: playlist.crossfade, role: .playlist)
        }
        if settings.clipAudio.enabled, clip.hasAudio {
            let source = try await sourceTrack(for: clip.url)
            sourceAssets.append(source.asset)
            let audioLength = source.duration
            let track = try addTrack(to: composition)
            var placements: [AudioPlacement] = []
            for (index, start) in plan.insertTimes.enumerated() {
                let copyLength = index == plan.fullCopies ? plan.remainder.seconds : plan.clipDuration.seconds
                let length = min(audioLength, copyLength)
                try insert(source.track, from: source.start, length: length, at: start.seconds, into: track)
                let edge = min(clipAudioEdgeFade, length / 2)
                placements.append(AudioPlacement(itemIndex: 0, start: start.seconds, length: length, track: 0,
                                                 fadeIn: index == 0 ? 0 : edge,
                                                 fadeOut: index == plan.copyCount - 1 ? 0 : edge))
            }
            tracks.append(track)
            mixes.append(AudioTrackMix(trackID: track.trackID, role: .clipAudio, placements: placements,
                                       itemNames: [clip.url.lastPathComponent]))
        }

        guard !tracks.isEmpty else { return nil }
        let mix = audioMix(for: mixes, total: total) { settings.track(for: $0) }
        return LoopAudio(composition: composition, audioMix: mix, tracks: tracks, mixes: mixes,
                         sourceAssets: sourceAssets)
    }

    /// The volume ramps for `mixes`, with each role's level and fades from `settings`
    /// (silent where it returns nil). Tracks are matched by ID, so the mix also works on
    /// a copy of the composition.
    static func audioMix(for mixes: [AudioTrackMix], total: Double,
                         settings: (AudioRole) -> AudioTrackSettings?) -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixes.map { track in
            let silent = AudioTrackSettings(volume: 0, fadeIn: 0, fadeOut: 0)
            return mixParameters(for: track.trackID, placements: track.gainPlacements,
                                 settings: settings(track.role) ?? silent, total: total)
        }
        return mix
    }

    private struct Source {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let start: CMTime
        let duration: Double
    }

    private static func sourceTrack(for url: URL) async throws -> Source {
        let asset = AVURLAsset(url: url, options: ClipInfo.assetOptions)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioSourceError.noAudio(url.lastPathComponent)
        }
        let range = try await track.load(.timeRange)
        return Source(asset: asset, track: track, start: range.start, duration: range.duration.seconds)
    }

    private static func addTrack(to composition: AVMutableComposition) throws -> AVMutableCompositionTrack {
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LoopComposerError.cannotAddTrack
        }
        return track
    }

    /// Inserts `length` seconds of `source` from its start at output time `at`, padding
    /// any gap before it with an empty segment.
    private static func insert(_ source: AVAssetTrack, from sourceStart: CMTime, length: Double, at start: Double,
                               into track: AVMutableCompositionTrack) throws {
        let at = time(start)
        // An empty track's time range is zero, so the first piece also gets its lead-in gap.
        let end = track.timeRange.end
        if end.isValid, at > end {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
        }
        try track.insertTimeRange(CMTimeRange(start: sourceStart, duration: time(length, roundingDown: true)), of: source, at: at)
    }

    private static func mixParameters(for trackID: CMPersistentTrackID, placements: [AudioPlacement],
                                      settings: AudioTrackSettings, total: Double) -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = trackID
        let points = GainEnvelope.points(for: placements, volume: settings.volume,
                                         fadeIn: settings.fadeIn, fadeOut: settings.fadeOut, total: total)
        guard let first = points.first else { return parameters }
        parameters.setVolume(first.gain, at: time(first.time))
        for (a, b) in zip(points, points.dropFirst()) {
            parameters.setVolumeRamp(fromStartVolume: a.gain, toEndVolume: b.gain,
                                     timeRange: CMTimeRange(start: time(a.time), end: time(b.time)))
        }
        return parameters
    }

    static func time(_ seconds: Double, roundingDown: Bool = false) -> CMTime {
        let units = seconds * Double(timescale)
        return CMTime(value: CMTimeValue(roundingDown ? units.rounded(.down) : units.rounded()), timescale: timescale)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
