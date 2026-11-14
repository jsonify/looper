import AVFoundation
import Testing
@testable import LooperCore

/// #18: seams are frame exact and video is passed through unchanged.
@Suite("Seams", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct SeamTests {
    static let fixtures: [VideoFixture] = [.main, .fps24, .fps2997]

    /// 2:10 = 4 full copies of a 30 s clip plus a trimmed one.
    @Test(arguments: fixtures)
    func everyFrameFollowsThePreviousAcrossSeams(_ fixture: VideoFixture) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (asset, plan) = try await exportLoop(fixture, seconds: 130, in: folder)
        #expect(plan.fullCopies == 4)
        #expect(plan.remainderFrames > 0)

        let ids = try await MediaInspection.frameIDs(of: asset, bitBlock: fixture.bitBlock)
        let expected = (0..<plan.frameCount).map { $0 % fixture.frameCount }
        #expect(ids.count == plan.frameCount)
        if ids != expected {
            let firstBad = ids.indices.first { $0 >= expected.count || ids[$0] != expected[$0] } ?? ids.count
            let window = max(0, firstBad - 3)..<min(ids.count, firstBad + 4)
            Issue.record("frame \(firstBad) differs; got \(Array(ids[window])) around it")
        }
    }

    @Test(arguments: fixtures)
    func presentationTimesAreEvenlySpaced(_ fixture: VideoFixture) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (asset, plan) = try await exportLoop(fixture, seconds: 130, in: folder)
        let times = try await MediaInspection.decodedFrameTimes(of: asset)
        #expect(times.count == plan.frameCount)
        let frame = plan.frameDuration
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        let uneven = gaps.enumerated().filter { abs(($0.element - frame).seconds) > 1e-6 }
        #expect(uneven.isEmpty, "uneven gaps at frames \(uneven.prefix(5).map(\.offset)): \(uneven.prefix(5).map { $0.element.seconds })")
    }

    /// The same frames come out when ffmpeg decodes the file (YouTube's ingest is
    /// ffmpeg-like), so the multi-segment edit list is read the same way there.
    @Test(.enabled(if: FFmpeg.available || FFmpeg.required, "ffmpeg not installed"), arguments: fixtures)
    func ffmpegDecodesTheSameFrames(_ fixture: VideoFixture) async throws {
        try #require(FFmpeg.available, "ffmpeg/ffprobe required (LOOPER_REQUIRE_FFMPEG=1) but not found")
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (asset, plan) = try await exportLoop(fixture, seconds: 130, in: folder)
        #expect(try FFmpeg.frameCount(of: asset.url) == plan.frameCount)
        let ids = try FFmpeg.frameIDs(of: asset.url, bitBlock: fixture.bitBlock)
        #expect(ids.count == plan.frameCount)
        #expect(ids == (0..<plan.frameCount).map { $0 % fixture.frameCount })
    }

    /// Records why loops aren't exported with AVAssetExportSession passthrough: ffmpeg
    /// holds frame N-2 for two extra frames at the first seam of such a file. If this
    /// known issue stops reproducing (a macOS fix), the test fails to say so.
    @Test(.enabled(if: FFmpeg.available || FFmpeg.required, "ffmpeg not installed"))
    func passthroughCompositionTripsUpFFmpeg() async throws {
        try #require(FFmpeg.available, "ffmpeg/ffprobe required (LOOPER_REQUIRE_FFMPEG=1) but not found")
        let fixture = VideoFixture.fps24
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let clip = try await ClipInfo.load(from: fixture.url)
        let plan = LoopPlan(clip: clip, target: try TargetDuration(seconds: 130))
        let loop = try await LoopComposer.compose(clip: clip, plan: plan)
        let output = folder.file("passthrough.mp4")
        try await PassthroughExporter().export(loop.composition, to: output)
        let ids = try FFmpeg.frameIDs(of: output, bitBlock: fixture.bitBlock)
        withKnownIssue("ffmpeg misreads per-copy edit lists from passthrough export") {
            #expect(ids == (0..<plan.frameCount).map { $0 % fixture.frameCount })
        }
    }

    /// Video is copied, not re-encoded: the output's compressed samples for full copies are byte-identical
    /// to the source's, repeated.
    @Test(arguments: fixtures)
    func fullCopiesAreByteIdenticalToTheSource(_ fixture: VideoFixture) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (asset, plan) = try await exportLoop(fixture, seconds: 130, in: folder)
        let source = try await MediaInspection.videoSampleHashes(of: AVURLAsset(url: fixture.url))
        let output = try await MediaInspection.videoSampleHashes(of: asset)
        #expect(source.count == fixture.frameCount)
        let fullCopySamples = plan.fullCopies * fixture.frameCount
        try #require(output.count >= fullCopySamples)
        let expected = Array(repeating: source, count: plan.fullCopies).flatMap { $0 }
        #expect(Array(output.prefix(fullCopySamples)) == expected)
    }
}
