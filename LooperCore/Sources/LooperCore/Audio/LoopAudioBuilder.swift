import AVFoundation

/// An audio-only timeline for one export plus the mix (levels, fades, crossfades) to
/// render it with. Mixed down to one AAC track by `LoopWriter`.
struct LoopAudio {
    let composition: AVMutableComposition
    let audioMix: AVAudioMix
    let tracks: [AVMutableCompositionTrack]
    /// The source files. An AVAssetTrack doesn't keep its asset alive, so the assets
    /// are held here for as long as the composition is read.
    let sourceAssets: [AVAsset]
}

/// Builds the audio timeline: the bed and playlist chained with crossfades on
/// alternating track pairs, and the clip's own audio aligned with each video copy.
enum LoopAudioBuilder {
    /// Timescale for audio placements: one unit per sample at 48 kHz.
    static let timescale: CMTimeScale = 48_000

    /// Short fades at each copy edge of clip audio, so the tiny gaps where an AAC track
    /// is a few ms shorter than the video don't click.
    static let clipAudioEdgeFade = 0.01

    static func build(settings: LoopAudioSettings, clip: ClipInfo, plan: LoopPlan) async throws -> LoopAudio? {
        let total = plan.duration.seconds
        let composition = AVMutableComposition()
        var tracks: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        var sourceAssets: [AVAsset] = []

        func addChain(items: [AudioItem], crossfade: Double, track settings: AudioTrackSettings) async throws {
            let placements = AudioChain.placements(itemDurations: items.map(\.seconds), crossfade: crossfade, fill: total)
            let sources = try await items.asyncMap { try await sourceTrack(for: $0.url) }
            sourceAssets += sources.map(\.asset)
            for trackIndex in 0..<2 {
                let onTrack = placements.filter { $0.track == trackIndex }
                guard !onTrack.isEmpty else { continue }
                let track = try addTrack(to: composition)
                for p in onTrack {
                    let source = sources[p.itemIndex]
                    try insert(source.track, from: source.start, length: p.length, at: p.start, into: track)
                }
                tracks.append(track)
                parameters.append(mixParameters(for: track, placements: onTrack, settings: settings, total: total))
            }
        }

        if let bed = settings.bed {
            let item = try await AudioItem.load(from: bed.file)
            try await addChain(items: [item], crossfade: bed.wrapCrossfade, track: bed.track)
        }
        if let playlist = settings.playlist {
            let items = try await FolderAudioSource(folder: playlist.folder).items()
            try await addChain(items: items, crossfade: playlist.crossfade, track: playlist.track)
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
            parameters.append(mixParameters(for: track, placements: placements, settings: settings.clipAudio.track, total: total))
        }

        guard !tracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return LoopAudio(composition: composition, audioMix: mix, tracks: tracks, sourceAssets: sourceAssets)
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

    private static func mixParameters(for track: AVMutableCompositionTrack, placements: [AudioPlacement],
                                      settings: AudioTrackSettings, total: Double) -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
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
