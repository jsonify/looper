import Foundation
import Testing
@testable import LooperCore

@Suite("AudioChain")
struct AudioChainTests {
    @Test func bedWrapsWithCrossfades() {
        let p = AudioChain.placements(itemDurations: [10], crossfade: 2, fill: 30)
        #expect(p.map(\.start) == [0, 8, 16, 24])
        #expect(p.map(\.track) == [0, 1, 0, 1])
        #expect(p.map(\.fadeIn) == [0, 2, 2, 2])
        #expect(p.map(\.fadeOut) == [2, 2, 2, 0])
        #expect(p.last?.length == 6) // trimmed to end at 30
        #expect(p.last?.end == 30)
    }

    @Test func playlistCyclesInOrder() {
        let p = AudioChain.placements(itemDurations: [6, 6, 6], crossfade: 1, fill: 40)
        #expect(p.map(\.itemIndex) == [0, 1, 2, 0, 1, 2, 0, 1])
        #expect(p.map(\.start) == [0, 5, 10, 15, 20, 25, 30, 35])
        #expect(p.last?.end == 40)
    }

    @Test func crossfadeIsClampedToHalfAPiece() {
        let p = AudioChain.placements(itemDurations: [4], crossfade: 10, fill: 10)
        // Each 4 s piece advances 2 s; the piece starting at 6 reaches 10 and is the last.
        #expect(p.map(\.start) == [0, 2, 4, 6])
        #expect(p.dropFirst().allSatisfy { $0.fadeIn == 2 })
    }

    @Test func zeroCrossfadeIsBackToBack() {
        let p = AudioChain.placements(itemDurations: [6, 4], crossfade: 0, fill: 20)
        #expect(p.map(\.start) == [0, 6, 10, 16])
        #expect(p.allSatisfy { $0.fadeIn == 0 && $0.fadeOut == 0 })
    }

    @Test func shortFillUsesPartOfOnePiece() {
        let p = AudioChain.placements(itemDurations: [600], crossfade: 3, fill: 30)
        #expect(p == [AudioPlacement(itemIndex: 0, start: 0, length: 30, track: 0, fadeIn: 0, fadeOut: 0)])
    }

    @Test func piecesOnOneTrackNeverOverlap() {
        let p = AudioChain.placements(itemDurations: [7, 3, 11], crossfade: 4, fill: 300)
        for track in 0..<2 {
            let onTrack = p.filter { $0.track == track }
            #expect(zip(onTrack, onTrack.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 })
        }
    }
}

@Suite("SilenceTrim")
struct SilenceTrimTests {
    /// Peaks per 10 ms window: `silent` windows of near-silence around `loud` windows.
    func peaks(lead: Int, loud: Int, tail: Int) -> [Float] {
        Array(repeating: 0.0001, count: lead) + Array(repeating: 0.3, count: loud) + Array(repeating: 0.0001, count: tail)
    }

    @Test func trimsLeadingAndTrailingSilence() throws {
        let trim = try #require(SilenceTrim.audibleRange(windowPeaks: peaks(lead: 80, loud: 900, tail: 20),
                                                         windowSeconds: 0.01, totalSeconds: 10))
        #expect(abs(trim.start - 0.8) < 1e-9)
        #expect(abs(trim.end - 9.8) < 1e-9)
    }

    @Test func tinyTrimsAreIgnored() throws {
        #expect(SilenceTrim.audibleRange(windowPeaks: peaks(lead: 2, loud: 996, tail: 2),
                                         windowSeconds: 0.01, totalSeconds: 10) == nil)
        // Only the end is worth trimming: the start stays at 0.
        let trim = try #require(SilenceTrim.audibleRange(windowPeaks: peaks(lead: 2, loud: 898, tail: 100),
                                                         windowSeconds: 0.01, totalSeconds: 10))
        #expect(trim.start == 0)
        #expect(abs(trim.end - 9) < 1e-9)
    }

    @Test func allSilenceIsNotTrimmed() {
        #expect(SilenceTrim.audibleRange(windowPeaks: Array(repeating: 0, count: 500),
                                         windowSeconds: 0.01, totalSeconds: 5) == nil)
    }

    @Test func trimmedItemPlaysOnlyTheRange() {
        let item = AudioItem(url: URL(fileURLWithPath: "/tmp/rec.mp4"), seconds: 30, codec: "aac ", sampleRate: 48_000, channels: 2)
        #expect(item.isFromVideo)
        let trimmed = item.trimmed(AudioTrim(start: 0.8, end: 30.5)) // end clamped to the file
        #expect(trimmed.start == 0.8)
        #expect(abs(trimmed.seconds - 29.2) < 1e-9)
        #expect(trimmed.fileSeconds == 30)
        #expect(trimmed.trimmed(nil) == item)
    }
}

@Suite("GainEnvelope")
struct GainEnvelopeTests {
    let placements = AudioChain.placements(itemDurations: [10], crossfade: 2, fill: 30)

    func gain(_ t: Double, track: Int, fadeIn: Double = 0, fadeOut: Double = 0) -> Double {
        Double(GainEnvelope.gain(at: t, placements: placements.filter { $0.track == track }, volume: 0.8,
                                 fadeIn: fadeIn, fadeOut: fadeOut, total: 30))
    }

    /// Equal power: through each crossfade, the summed power stays at volume².
    @Test func crossfadesKeepConstantPower() {
        for t in stride(from: 8.0, through: 10.0, by: 0.1) {
            let power = pow(gain(t, track: 0), 2) + pow(gain(t, track: 1), 2)
            #expect(abs(power - 0.64) < 1e-6, "t=\(t) power \(power)")
        }
    }

    @Test func steadyAtVolumeBetweenCrossfades() {
        #expect(abs(gain(5, track: 0) - 0.8) < 1e-6)
        #expect(gain(5, track: 1) == 0)
    }

    @Test func trackFadesAtStartAndEnd() {
        #expect(gain(0, track: 0, fadeIn: 4) == 0)
        #expect(abs(gain(4, track: 0, fadeIn: 4) - 0.8) < 1e-6)
        #expect(gain(30, track: 1, fadeOut: 5) < 1e-6)
    }

    /// The linear ramps between points stay close to the true curve.
    @Test func rampsApproximateTheCurve() {
        let onTrack = placements.filter { $0.track == 1 }
        let points = GainEnvelope.points(for: onTrack, volume: 1, fadeIn: 0, fadeOut: 0, total: 30)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time })
        for (a, b) in zip(points, points.dropFirst()) where b.time - a.time < 1 {
            let mid = (a.time + b.time) / 2
            let linear = Double(a.gain + b.gain) / 2
            let exact = Double(GainEnvelope.gain(at: mid, placements: onTrack, volume: 1, fadeIn: 0, fadeOut: 0, total: 30))
            #expect(abs(linear - exact) < 0.02, "t=\(mid)")
        }
    }
}

@Suite("Audio sources", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct AudioSourceTests {
    @Test func folderListsSongsInOrder() async throws {
        let items = try await FolderAudioSource(folder: Fixtures.url(AudioFixture.playlistDirectory)).items()
        #expect(items.map(\.name) == ["01-tone-220.wav", "02-tone-330.aiff", "03-tone-440.flac"])
        #expect(items.allSatisfy { $0.isLossless && abs($0.seconds - 6) < 0.01 && $0.channels == 2 && $0.sampleRate == 48_000 })
    }

    @Test func bedLoads() async throws {
        let bed = try await FileAudioSource(url: AudioFixture.bed.url).items()
        #expect(bed.count == 1)
        #expect(bed[0].codec == "lpcm")
    }

    @Test func compressedAudioIsNotLossless() async throws {
        let item = try await AudioItem.load(from: VideoFixture.withAudio.url)
        #expect(item.codec == "aac ")
        #expect(!item.isLossless)
    }

    @Test func errors() async throws {
        await #expect(throws: AudioSourceError.noAudio("loop-tiny30.mp4")) {
            try await AudioItem.load(from: VideoFixture.tiny.url)
        }
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try Data().write(to: folder.file("notes.txt"))
        await #expect(throws: AudioSourceError.self) {
            try await FolderAudioSource(folder: folder.url).items()
        }
    }
}

/// A rendered bed repeats so each crossfade lands where the chain puts it.
@Suite("BedLoop")
struct BedLoopTests {
    @Test func segmentsMatchTheChain() {
        // 10 s bed, 2 s overlap, 30 s: the chain's crossfades are at 8–10, 16–18, 24–26 s.
        let loop = BedLoop(url: URL(fileURLWithPath: "/dev/null"), frames: 480_000, overlapFrames: 96_000)
        let s = loop.segments(totalFrames: 30 * 48_000)
        #expect(s.map(\.from) == [0, 96_000, 96_000, 96_000])
        #expect(s.map(\.at) == [0, 480_000, 864_000, 1_248_000])        // 0, 10, 18, 26 s
        #expect(s.map(\.length) == [480_000, 384_000, 384_000, 192_000]) // last trimmed to end at 30 s
        // Each repeat's blend (the file's last 2 s) ends where a chain crossfade ends.
        let blendEnds = s.dropLast().map { Double($0.at + $0.length) / 48_000 }
        #expect(blendEnds == [10, 18, 26])
        let chain = AudioChain.placements(itemDurations: [10], crossfade: 2, fill: 30)
        #expect(chain.dropFirst().map { $0.start + $0.fadeIn } == [10, 18, 26])
    }

    @Test func noOverlapRepeatsTheWholeFile() {
        let loop = BedLoop(url: URL(fileURLWithPath: "/dev/null"), frames: 480_000, overlapFrames: 0)
        let s = loop.segments(totalFrames: 25 * 48_000)
        #expect(s.map(\.from) == [0, 0, 0])
        #expect(s.map(\.length) == [480_000, 480_000, 240_000])
    }

    @Test func shortFadesAreOneRamp() {
        let piece = AudioPlacement(itemIndex: 0, start: 0, length: 30, track: 0, fadeIn: 0.01, fadeOut: 0.01)
        let points = GainEnvelope.points(for: [piece], volume: 1, fadeIn: 0, fadeOut: 0, total: 30)
        #expect(points.map(\.time) == [0, 0.01, 29.99, 30])
    }
}
