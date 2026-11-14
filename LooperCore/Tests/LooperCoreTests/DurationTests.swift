import AVFoundation
import Testing
@testable import LooperCore

/// #19: exact duration and frame count, including targets that aren't a whole number
/// of copies.
@Suite("Duration", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct DurationTests {
    @Test func oneHourTenSecondsIsExactAndEndsOnFrame299() async throws {
        let fixture = VideoFixture.tiny
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (asset, plan) = try await exportLoop(fixture, seconds: 3610, in: folder)
        #expect(plan.frameCount == 108_300)

        let track = try await MediaInspection.videoTrack(of: asset)
        let timeRange = try await track.load(.timeRange)
        #expect(abs((timeRange.duration - CMTime(value: 3610, timescale: 1)).seconds) < 1e-6,
                "video duration \(timeRange.duration.seconds)")
        #expect(try await MediaInspection.videoSampleCount(of: asset) == 108_300)

        // Decode only the last 2 s: the final copy is 10 s long, so it must end on frame 299.
        let tail = CMTimeRange(start: CMTime(value: 3608, timescale: 1), end: CMTime(value: 3610, timescale: 1))
        let ids = try await MediaInspection.frameIDs(of: asset, bitBlock: fixture.bitBlock, timeRange: tail)
        #expect(ids.last == 299)
        #expect(isContinuousLoop(ids, frameCount: fixture.frameCount))
    }

    @Test func targetShorterThanOneClip() async throws {
        let fixture = VideoFixture.tiny
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (asset, _) = try await exportLoop(fixture, seconds: 10, in: folder)
        let ids = try await MediaInspection.frameIDs(of: asset, bitBlock: fixture.bitBlock)
        #expect(ids == Array(0..<300))
    }

    /// Expected counts come from each clip's real frame rate.
    @Test(arguments: [(VideoFixture.fps24, 1680), (VideoFixture.fps2997, 2097)])
    func otherFrameRates(_ fixture: VideoFixture, expectedFrames: Int) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // 70 s: 24 fps → 1680 frames; 29.97 fps → floor(70 × 30000 / 1001) = 2097 frames.
        let (asset, plan) = try await exportLoop(fixture, seconds: 70, in: folder)
        #expect(plan.frameCount == expectedFrames)
        let ids = try await MediaInspection.frameIDs(of: asset, bitBlock: fixture.bitBlock)
        #expect(ids == (0..<expectedFrames).map { $0 % fixture.frameCount })
    }
}
