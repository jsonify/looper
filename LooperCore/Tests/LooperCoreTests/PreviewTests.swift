import AVFoundation
import Testing
@testable import LooperCore

/// The preview's timeline math: seams, jumps and the level line.
@Suite("PreviewTimeline")
struct PreviewTimelineTests {
    /// 3 h of a 30 s clip, a bed wrapping every 8 s (10 s, 2 s crossfade), three 6 s songs.
    func timeline(duration: Double = 3 * 3600) -> PreviewTimeline {
        let bed = AudioChain.placements(itemDurations: [10], crossfade: 2, fill: duration)
        let songs = AudioChain.placements(itemDurations: [100, 200, 300], crossfade: 3, fill: duration)
        func pieces(_ p: [AudioPlacement], _ names: [String]) -> [PreviewTimeline.Piece] {
            p.map { .init(title: names[$0.itemIndex], start: $0.start, length: $0.length,
                          fadeIn: $0.fadeIn, fadeOut: $0.fadeOut, track: $0.track) }
        }
        return PreviewTimeline(duration: duration, clipDuration: 30, frameDuration: 1.0 / 30,
                               copyCount: Int((duration / 30).rounded(.up)),
                               lanes: [.init(role: .playlist, pieces: pieces(songs, ["a", "b", "c"])),
                                       .init(role: .bed, pieces: pieces(bed, ["bed"]))])
    }

    @Test func lanesAreInDisplayOrder() {
        #expect(timeline().lanes.map(\.role) == [.bed, .playlist])
    }

    @Test func positionNamesCopyAndFrame() {
        let t = timeline()
        func position(_ time: Double) -> [Int] { let p = t.position(at: time); return [p.copy, p.frame] }
        #expect(position(0) == [1, 0])
        #expect(position(29.99) == [1, 899])
        #expect(position(30) == [2, 0])
        #expect(position(30 + 10.0 / 30) == [2, 10])
        #expect(position(3 * 3600) == [360, 900]) // the very end, past the last frame
    }

    @Test func nextSeamLandsJustBeforeIt() {
        let t = timeline()
        #expect(t.time(for: .nextSeam, from: 0) == 27)
        // Sitting at the landing spot, the next press moves on.
        #expect(t.time(for: .nextSeam, from: 27) == 57)
        #expect(t.time(for: .nextSeam, from: 40) == 57)
        // No seam after the last copy starts.
        #expect(t.time(for: .nextSeam, from: 3 * 3600 - 20) == nil)
    }

    @Test func nextBedWrapAndSongChange() {
        let t = timeline()
        #expect(t.bedWraps.prefix(3) == [8, 16, 24])
        #expect(t.time(for: .nextBedWrap, from: 0) == 5)
        #expect(t.time(for: .nextBedWrap, from: 5) == 13)
        #expect(t.songChanges.prefix(2) == [97, 294])
        #expect(t.time(for: .nextSongChange, from: 0) == 94)
        #expect(t.time(for: .nextSongChange, from: 94) == 291)
    }

    @Test func jumpsWithoutTheirAudioGoNowhere() {
        let t = PreviewTimeline(duration: 60, clipDuration: 30, frameDuration: 1.0 / 30, copyCount: 2, lanes: [])
        #expect(t.time(for: .nextBedWrap, from: 0) == nil)
        #expect(t.time(for: .nextSongChange, from: 0) == nil)
        #expect(t.time(for: .nextSeam, from: 0) == 27)
    }

    @Test func finalFadeAndStart() {
        let t = timeline()
        #expect(t.time(for: .finalFade, from: 0, finalFade: 60) == Double(3 * 3600 - 63))
        #expect(t.time(for: .start, from: 500) == 0)
        #expect(t.time(for: .finalFade, from: 0, finalFade: 99_999) == 0)
    }

    /// Equal-power crossfades keep the summed level flat, so the line doesn't dip at a wrap.
    @Test func levelIsFlatThroughCrossfadesAndFollowsFades() {
        let t = timeline()
        let settings = AudioTrackSettings(volume: 0.5, fadeIn: 4, fadeOut: 60)
        for time in stride(from: 6.0, through: 26, by: 0.25) {
            #expect(abs(t.level(.bed, at: time, settings: settings) - 0.5) < 0.01, "at \(time)")
        }
        #expect(t.level(.bed, at: 0, settings: settings) == 0)
        #expect(t.level(.bed, at: 2, settings: settings) < 0.5)
        #expect(t.level(.bed, at: 3 * 3600 - 30, settings: settings) < 0.4)
        #expect(t.level(.clipAudio, at: 10, settings: settings) == 0)
    }
}

/// The playable preview: the same layout as the export, in one composition.
@Suite("LoopPreview", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"),
       .timeLimit(.minutes(1)))
struct LoopPreviewTests {
    static let flat = AudioTrackSettings(volume: 1, fadeIn: 0, fadeOut: 0)

    var audio: LoopAudioSettings {
        LoopAudioSettings(bed: BedSettings(file: AudioFixture.bed.url, track: Self.flat, wrapCrossfade: 2),
                          playlist: PlaylistSettings(folder: Fixtures.url(AudioFixture.playlistDirectory), track: Self.flat))
    }

    @Test func buildsVideoAndAudioOnOneTimeline() async throws {
        let clip = try await ClipInfo.load(from: VideoFixture.tiny.url)
        let plan = LoopPlan(clip: clip, target: try TargetDuration(seconds: 70))
        let preview = try await LoopPreview.build(clip: clip, plan: plan, audio: audio)

        let video = try await preview.composition.loadTracks(withMediaType: .video)
        let audioTracks = try await preview.composition.loadTracks(withMediaType: .audio)
        #expect(video.count == 1)
        #expect(audioTracks.count == 3) // the rendered bed on one track, the playlist on two alternating
        let videoRange = try await video[0].load(.timeRange)
        #expect(videoRange.duration == plan.duration)

        let timeline = preview.timeline
        #expect(timeline.copyCount == 3)
        #expect(timeline.lanes.map(\.role) == [.bed, .playlist])
        #expect(timeline.bedWraps.prefix(2) == [8, 16])
        #expect(timeline.lane(.playlist)?.pieces.prefix(3).map(\.title) == ["01-tone-220.wav", "02-tone-330.aiff", "03-tone-440.flac"])

        let mix = try #require(preview.audioMix(for: [.bed: Self.flat, .playlist: Self.flat]))
        let ids = Set(audioTracks.map(\.trackID))
        #expect(Set(mix.inputParameters.map(\.trackID)) == ids)
    }

    /// A role left out of the settings (muted) gets zero volume; the others keep theirs.
    @Test func mixSilencesMissingRoles() async throws {
        let clip = try await ClipInfo.load(from: VideoFixture.tiny.url)
        let plan = LoopPlan(clip: clip, target: try TargetDuration(seconds: 30))
        let preview = try await LoopPreview.build(clip: clip, plan: plan, audio: audio)
        let mix = try #require(preview.audioMix(for: [.playlist: Self.flat]))
        let bedIDs = Set(preview.mixes.filter { $0.role == .bed }.map(\.trackID))
        // The playlist track that plays the first song, from 0 s.
        let playlistFirst = preview.mixes.first { $0.role == .playlist && $0.placements.first?.start == 0 }?.trackID
        for parameters in mix.inputParameters {
            var start: Float = -1, end: Float = -1
            var range = CMTimeRange.zero
            let found = parameters.getVolumeRamp(for: CMTime(seconds: 1, preferredTimescale: 48_000),
                                                 startVolume: &start, endVolume: &end, timeRange: &range)
            #expect(found)
            if bedIDs.contains(parameters.trackID) { #expect(start == 0 && end == 0) }
            if parameters.trackID == playlistFirst { #expect(start == 1) }
        }
    }

    @Test func silentPreviewHasNoAudio() async throws {
        let clip = try await ClipInfo.load(from: VideoFixture.tiny.url)
        let plan = LoopPlan(clip: clip, target: try TargetDuration(seconds: 45))
        let preview = try await LoopPreview.build(clip: clip, plan: plan, audio: LoopAudioSettings())
        #expect(try await preview.composition.loadTracks(withMediaType: .audio).isEmpty)
        #expect(preview.audioMix(for: [:]) == nil)
        #expect(preview.timeline.lanes.isEmpty)
    }
}

@MainActor
@Suite("PreviewModel", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"),
       .timeLimit(.minutes(1)))
struct PreviewModelTests {
    func bedAudio(volume: Float = 0.6, crossfade: Double = 2) -> LoopAudioSettings {
        LoopAudioSettings(bed: BedSettings(file: AudioFixture.bed.url,
                                           track: AudioTrackSettings(volume: volume, fadeIn: 1, fadeOut: 5),
                                           wrapCrossfade: crossfade))
    }

    @Test func unavailableWithoutAClip() async {
        let model = PreviewModel()
        await model.update(clip: nil, plan: nil, audio: LoopAudioSettings())
        #expect(model.state == .unavailable("Choose a loop clip in the main window."))
        #expect(model.timeline == nil)
    }

    @Test func levelChangesKeepTheItemLayoutChangesRebuild() async throws {
        let clip = try await ClipInfo.load(from: VideoFixture.tiny.url)
        let plan = LoopPlan(clip: clip, target: try TargetDuration(seconds: 90))
        let model = PreviewModel()
        await model.update(clip: clip, plan: plan, audio: bedAudio())
        #expect(model.state == .ready)
        let first = try #require(model.player.currentItem)
        #expect(first.audioMix != nil)

        model.seek(to: 40)
        await model.update(clip: clip, plan: plan, audio: bedAudio(volume: 0.2))
        #expect(model.player.currentItem === first, "a level change must not rebuild")

        await model.update(clip: clip, plan: plan, audio: bedAudio(volume: 0.2, crossfade: 3))
        let second = try #require(model.player.currentItem)
        #expect(second !== first, "a crossfade change rebuilds the timeline")
        #expect(model.currentTime == 40, "the playhead stays put across a rebuild")
    }

    @Test func muteAndSoloAffectOnlyThePreview() async throws {
        let clip = try await ClipInfo.load(from: VideoFixture.tiny.url)
        let plan = LoopPlan(clip: clip, target: try TargetDuration(seconds: 30))
        let model = PreviewModel()
        let audio = LoopAudioSettings(bed: bedAudio().bed,
                                      playlist: PlaylistSettings(folder: Fixtures.url(AudioFixture.playlistDirectory)))
        await model.update(clip: clip, plan: plan, audio: audio)
        model.muted = [.bed]
        #expect(model.trackSettings(for: .bed)?.volume == 0)
        #expect(model.trackSettings(for: .playlist)?.volume == audio.playlist?.track.volume)
        model.muted = []
        model.soloed = [.bed]
        #expect(model.trackSettings(for: .playlist)?.volume == 0)
        #expect(model.trackSettings(for: .bed)?.volume == 0.6)
    }

    @Test func jumpsMoveThePlayhead() async throws {
        let clip = try await ClipInfo.load(from: VideoFixture.tiny.url)
        let plan = LoopPlan(clip: clip, target: try TargetDuration(seconds: 120))
        let model = PreviewModel()
        await model.update(clip: clip, plan: plan, audio: bedAudio())
        model.jump(.nextSeam)
        #expect(model.currentTime == 27)
        model.jump(.nextBedWrap)
        #expect(model.currentTime == 29) // wraps at 8, 16, 24, 32...: next after 27 is 32
        model.jump(.finalFade)
        #expect(model.currentTime == 120 - 5 - 3)
        #expect(model.finalFadeLength == 5)
    }
}
