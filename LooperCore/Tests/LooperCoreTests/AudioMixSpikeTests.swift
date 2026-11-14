import AVFoundation
import Testing
@testable import LooperCore

/// #13 spike: does passthrough export honour an AVAudioMix, and can it mix two audio
/// tracks into one? The answer decides how M3 exports audio.
///
/// Each case builds 20 s of looped video with audio, applies a mix (track A at 0.5,
/// then ramping to 0 over 14–19 s), exports with the passthrough preset, and prints a
/// `SPIKE` line comparing output levels with the source. It records findings rather
/// than asserting an outcome; the conclusion lives in CLAUDE.md.
@Suite("Spike: AVAudioMix with passthrough",
       .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct AudioMixSpikeTests {
    enum Source: String, Sendable { case wavBed = "WAV bed", clipAAC = "clip AAC" }

    struct Case: Sendable, CustomTestStringConvertible {
        let source: Source
        let fileType: AVFileType
        let secondTrack: Bool
        var testDescription: String {
            "\(source.rawValue) → \(fileType == .mp4 ? "mp4" : "mov")\(secondTrack ? " + 2nd track" : "")"
        }
    }

    static let cases: [Case] = [
        Case(source: .wavBed, fileType: .mp4, secondTrack: false),
        Case(source: .wavBed, fileType: .mov, secondTrack: false),
        Case(source: .clipAAC, fileType: .mp4, secondTrack: false),
        Case(source: .clipAAC, fileType: .mov, secondTrack: false),
        Case(source: .clipAAC, fileType: .mp4, secondTrack: true),
        Case(source: .wavBed, fileType: .mov, secondTrack: true),
    ]

    /// Windows (seconds) where levels are compared: constant 0.5, mid-ramp (~0.25), silent.
    static let windows: [ClosedRange<Double>] = [2...4, 16.3...16.7, 19.3...19.8]

    @Test(arguments: cases)
    func passthroughWithAudioMix(_ spikeCase: Case) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }

        let composition = AVMutableComposition()
        let length = CMTime(value: 20, timescale: 1)

        // Video: the first 20 s of the tiny clip.
        let videoAsset = AVURLAsset(url: VideoFixture.tiny.url)
        let videoSource = try await MediaInspection.videoTrack(of: videoAsset)
        let video = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: videoSource, at: .zero)

        // Track A: the source audio, looped to 20 s.
        let sourceURL = spikeCase.source == .wavBed ? AudioFixture.bed.url : VideoFixture.withAudio.url
        let sourceAsset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let sourceTrack = try #require(try await sourceAsset.loadTracks(withMediaType: .audio).first)
        let sourceDuration = try await sourceTrack.load(.timeRange).duration
        let trackA = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        var cursor = CMTime.zero
        while cursor < length {
            let piece = sourceDuration < length - cursor ? sourceDuration : length - cursor
            try trackA.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: sourceTrack, at: cursor)
            cursor = cursor + piece
        }

        let paramsA = AVMutableAudioMixInputParameters(track: trackA)
        paramsA.setVolume(0.5, at: .zero)
        paramsA.setVolumeRamp(fromStartVolume: 0.5, toEndVolume: 0,
                              timeRange: CMTimeRange(start: CMTime(value: 14, timescale: 1), duration: CMTime(value: 5, timescale: 1)))
        var parameters = [paramsA]

        // Optional track B: a 6 s tone at full volume, to see whether tracks get mixed.
        if spikeCase.secondTrack {
            let toneAsset = AVURLAsset(url: AudioFixture.playlist[0].url)
            let toneSource = try #require(try await toneAsset.loadTracks(withMediaType: .audio).first)
            let trackB = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try trackB.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 6, timescale: 1)), of: toneSource, at: .zero)
            let paramsB = AVMutableAudioMixInputParameters(track: trackB)
            paramsB.setVolume(1, at: .zero)
            parameters.append(paramsB)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters

        // Reference levels from the unmixed source at the same positions (the bed is
        // 10 s, so 16.5 s in the output is 6.5 s into the bed).
        let sourceWindows = Self.windows.map { window in
            let offset = spikeCase.source == .wavBed ? (window.lowerBound >= 10 ? 10.0 : 0) : 0
            return (window.lowerBound - offset)...(window.upperBound - offset)
        }
        let reference = try await MediaInspection.audioRMS(of: sourceTrack, in: sourceAsset, windows: sourceWindows)

        let output = folder.file(spikeCase.fileType == .mp4 ? "out.mp4" : "out.mov")
        var line = "SPIKE [\(spikeCase.testDescription)]: "
        do {
            try await PassthroughExporter().export(composition, audioMix: mix, fileType: spikeCase.fileType,
                                                   to: output, overwrite: false) { _ in }
            let result = AVURLAsset(url: output)
            let audioTracks = try await result.loadTracks(withMediaType: .audio)
            line += "exported; audio tracks=\(audioTracks.count)"
            for (index, track) in audioTracks.enumerated() {
                let format = try await MediaInspection.audioFormat(of: track)
                let levels = try await MediaInspection.audioRMS(of: track, in: result, windows: Self.windows)
                let ratios = zip(levels, reference).map { $1 > 0 ? $0 / $1 : 0 }
                line += "; track \(index): \(format.codec) \(Int(format.sampleRate)) Hz \(format.channels) ch, "
                line += "level vs source at 2-4s / 16.5s / 19.5s = "
                line += ratios.map { String(format: "%.2f", $0) }.joined(separator: " / ")
                line += " (mix honoured ≈ 0.50 / 0.25 / 0.00)"
            }
        } catch {
            line += "export failed: \(error.localizedDescription)"
        }
        print(line)
    }
}
