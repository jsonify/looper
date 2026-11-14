import AVFoundation
import Testing
@testable import LooperCore

/// M3 (#32–#36): exports with audio. Bed, playlist and clip audio are mixed through
/// AVAssetReaderAudioMixOutput into one AAC track; video stays a byte-for-byte copy.
@Suite("Audio export", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct AudioExportTests {
    static let quietTrack = AudioTrackSettings(volume: 1, fadeIn: 0, fadeOut: 0)

    func export(_ fixture: VideoFixture = .tiny, seconds: Int, audio: LoopAudioSettings,
                in folder: TemporaryFolder, name: String = "out.mp4") async throws -> (AVURLAsset, LoopPlan) {
        let clip = try await ClipInfo.load(from: fixture.url)
        let plan = LoopPlan(clip: clip, target: try TargetDuration(seconds: seconds))
        let url = folder.file(name)
        try await LoopWriter().export(clip: clip, plan: plan, audio: audio, to: url)
        return (AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]), plan)
    }

    func audioTrack(_ asset: AVAsset) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try #require(tracks.count == 1, "expected exactly one audio track, found \(tracks.count)")
        return tracks[0]
    }

    @Test func outputIsOneAACTrackAlignedWithTheVideo() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let audio = LoopAudioSettings(bed: BedSettings(file: AudioFixture.bed.url, track: Self.quietTrack, wrapCrossfade: 2),
                                      playlist: PlaylistSettings(folder: Fixtures.url(AudioFixture.playlistDirectory)))
        let (asset, plan) = try await export(seconds: 60, audio: audio, in: folder)
        let track = try await audioTrack(asset)
        let format = try await MediaInspection.audioFormat(of: track)
        #expect(format.codec == "aac ")
        #expect(format.sampleRate == 48_000)
        #expect(format.channels == 2)

        let audioRange = try await track.load(.timeRange)
        let videoRange = try await MediaInspection.videoTrack(of: asset).load(.timeRange)
        #expect(abs(audioRange.start.seconds - videoRange.start.seconds) < 0.03, "audio starts at \(audioRange.start.seconds)")
        #expect(abs(audioRange.duration.seconds - plan.duration.seconds) < 0.03, "audio lasts \(audioRange.duration.seconds)")
    }

    /// The wrap crossfade hides the bed's loop point: loudness stays steady across every
    /// wrap (equal-power crossfade of different parts of the noise), no dips or bumps.
    @Test func bedWrapsWithoutDipsOrBumps() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let audio = LoopAudioSettings(bed: BedSettings(file: AudioFixture.bed.url, track: Self.quietTrack, wrapCrossfade: 2))
        let (asset, _) = try await export(seconds: 60, audio: audio, in: folder)
        let decoded = try await DecodedAudio.decode(try await audioTrack(asset), in: asset)
        // Half-second windows from 1 s to 59 s; wraps happen at 8–10, 16–18, ... s.
        let levels = stride(from: 1.0, to: 59.0, by: 0.5).map { decoded.rms(from: $0, to: $0 + 0.5) }
        let median = levels.sorted()[levels.count / 2]
        #expect(median > 0.01)
        let worst = levels.map { abs(decibels($0 / median)) }.max() ?? 0
        #expect(worst < 1.5, "loudness strays \(worst) dB from the median")
    }

    @Test func trackFadesAndVolume() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let full = LoopAudioSettings(bed: BedSettings(file: AudioFixture.bed.url, track: Self.quietTrack, wrapCrossfade: 2))
        let faded = LoopAudioSettings(bed: BedSettings(
            file: AudioFixture.bed.url, track: AudioTrackSettings(volume: 0.5, fadeIn: 2, fadeOut: 3), wrapCrossfade: 2))
        let (fullAsset, _) = try await export(seconds: 30, audio: full, in: folder, name: "full.mp4")
        let (fadedAsset, _) = try await export(seconds: 30, audio: faded, in: folder, name: "faded.mp4")
        let a = try await DecodedAudio.decode(try await audioTrack(fullAsset), in: fullAsset)
        let b = try await DecodedAudio.decode(try await audioTrack(fadedAsset), in: fadedAsset)

        let ratio = b.rms(from: 10, to: 20) / a.rms(from: 10, to: 20)
        #expect(abs(ratio - 0.5) < 0.05, "volume 0.5 gave a level ratio of \(ratio)")
        // Silent at the very start and end, half-way up a second into the fade in.
        #expect(b.rms(from: 0, to: 0.05) < 0.05 * b.rms(from: 10, to: 20))
        #expect(b.rms(from: 29.95, to: 30) < 0.1 * b.rms(from: 10, to: 20))
        #expect(b.rms(from: 1, to: 1.1) < b.rms(from: 10, to: 20))
    }

    /// Songs play in folder order, cycling, with crossfades between them.
    @Test func playlistPlaysSongsInOrder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let audio = LoopAudioSettings(playlist: PlaylistSettings(
            folder: Fixtures.url(AudioFixture.playlistDirectory), track: Self.quietTrack, crossfade: 1))
        let (asset, _) = try await export(seconds: 40, audio: audio, in: folder)
        let decoded = try await DecodedAudio.decode(try await audioTrack(asset), in: asset)
        // 6 s songs overlapping by 1 s start every 5 s; listen to each song's middle.
        let expected: [Double] = [220, 330, 440, 220, 330, 440, 220]
        for (k, frequency) in expected.enumerated() {
            let middle = Double(k) * 5 + 3
            let measured = decoded.frequency(from: middle - 0.8, to: middle + 0.8)
            #expect(abs(measured - frequency) < 5, "song \(k) at \(middle) s: \(measured) Hz, expected \(frequency)")
        }
    }

    @Test func clipAudioFollowsTheVideoCopies() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let audio = LoopAudioSettings(clipAudio: ClipAudioSettings(enabled: true, track: Self.quietTrack))
        let (asset, plan) = try await export(.withAudio, seconds: 70, audio: audio, in: folder)
        let decoded = try await DecodedAudio.decode(try await audioTrack(asset), in: asset)
        #expect(abs(decoded.duration - plan.duration.seconds) < 0.05)
        // The 440 Hz left channel continues through each copy.
        for middle in [15.0, 45.0, 65.0] {
            #expect(abs(decoded.frequency(from: middle - 1, to: middle + 1) - 440) < 5)
        }
    }

    /// Adding audio doesn't touch the video: every frame still follows the previous,
    /// for AVFoundation and for ffmpeg.
    @Test func videoIsUnchangedByAudio() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = VideoFixture.fps24
        let audio = LoopAudioSettings(bed: BedSettings(file: AudioFixture.bed.url))
        let (asset, plan) = try await export(fixture, seconds: 130, audio: audio, in: folder)
        let expected = (0..<plan.frameCount).map { $0 % fixture.frameCount }
        #expect(try await MediaInspection.frameIDs(of: asset, bitBlock: fixture.bitBlock) == expected)
        if FFmpeg.available {
            #expect(try FFmpeg.frameIDs(of: asset.url, bitBlock: fixture.bitBlock) == expected)
        }
    }

    @Test func noAudioSettingsMeansNoAudioTrack() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (asset, _) = try await export(seconds: 10, audio: LoopAudioSettings(), in: folder)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }
}

/// #39-style long run in CI: 8 h of tiny video with bed + playlist.
@Suite("Long audio export", .enabled(if: Fixtures.available && TestEnvironment.longTests,
                                     "Set LOOPER_LONG_TESTS=1 and generate fixtures to run"))
struct LongAudioExportTests {
    @Test func eightHoursWithBedAndPlaylist() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let clip = try await ClipInfo.load(from: VideoFixture.tiny.url)
        let plan = LoopPlan(clip: clip, target: .eightHours)
        let audio = LoopAudioSettings(bed: BedSettings(file: AudioFixture.bed.url),
                                      playlist: PlaylistSettings(folder: Fixtures.url(AudioFixture.playlistDirectory)))
        let url = folder.file("8h-audio.mp4")
        let memoryBefore = peakResidentBytes()
        let clock = ContinuousClock()
        let started = clock.now
        try await LoopWriter().export(clip: clip, plan: plan, audio: audio, to: url)
        let elapsed = clock.now - started
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        print("8 h export with audio: \(elapsed), output \(size / 1_000_000) MB, peak RSS \(memoryBefore / 1_000_000) → \(peakResidentBytes() / 1_000_000) MB")

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioRange = try await audioTrack.load(.timeRange)
        #expect(abs(audioRange.duration.seconds - plan.duration.seconds) < 0.05)
        // The last minute still has sound until the fade out.
        let lastMinute = CMTimeRange(start: CMTime(seconds: 8 * 3600 - 60, preferredTimescale: 600),
                                     duration: CMTime(seconds: 40, preferredTimescale: 600))
        let tail = try await DecodedAudio.decode(audioTrack, in: asset, timeRange: lastMinute)
        #expect(tail.rms(from: tail.start, to: tail.start + 30) > 0.01)
        if FFmpeg.available {
            #expect(try FFmpeg.frameCount(of: url) == plan.frameCount)
        }
    }
}
