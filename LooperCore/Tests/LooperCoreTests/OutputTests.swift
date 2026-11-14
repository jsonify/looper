import Foundation
import Testing
@testable import LooperCore

@Suite("OutputLayout")
struct OutputLayoutTests {
    @Test(arguments: [("8:00:00", "8h"), ("0:45:00", "45m"), ("1:30:00", "1h30m"),
                      ("1:00:10", "1h0m10s"), ("0:00:30", "30s"), ("1:30:15", "1h30m15s")])
    func versionNames(_ duration: String, _ name: String) throws {
        #expect(OutputLayout.versionName(for: try TargetDuration(parsing: duration)) == name)
    }

    @Test func videoGoesInClipAndVersionFolders() {
        let url = OutputLayout.videoURL(in: URL(fileURLWithPath: "/Movies/Looper"),
                                        clip: URL(fileURLWithPath: "/clips/cabin_rain_loop_30s_v2.MP4"),
                                        versionName: "8h")
        #expect(url.path == "/Movies/Looper/cabin_rain_loop_30s_v2/8h/video.mp4")
    }

    @Test func unsafeCharactersAreReplaced() {
        #expect(OutputLayout.folderName(forClip: URL(fileURLWithPath: "/x/rain: night.mp4")) == "rain- night")
        #expect(OutputLayout.safeName("...") == "Untitled")
        #expect(OutputLayout.safeName(".hidden") == "hidden")
    }

    @Test func nextAvailableSkipsExistingFiles() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let video = folder.file("video.mp4")
        #expect(OutputLayout.nextAvailable(video) == video)
        try Data().write(to: video)
        #expect(OutputLayout.nextAvailable(video).lastPathComponent == "video 2.mp4")
        try Data().write(to: folder.file("video 2.mp4"))
        #expect(OutputLayout.nextAvailable(video).lastPathComponent == "video 3.mp4")
    }
}

@Suite("SpaceCheck")
struct SpaceCheckTests {
    let gb: Int64 = 1_000_000_000

    @Test func levels() {
        #expect(SpaceCheck.evaluate(estimatedBytes: 10 * gb, availableBytes: 100 * gb).level == .ok)
        // 10 GB + 2 GB minimum margin doesn't fit in 11 GB.
        #expect(SpaceCheck.evaluate(estimatedBytes: 10 * gb, availableBytes: 11 * gb).level == .low)
        #expect(SpaceCheck.evaluate(estimatedBytes: 10 * gb, availableBytes: 9 * gb).level == .insufficient)
        // 100 GB needs a 10 GB margin.
        #expect(SpaceCheck.evaluate(estimatedBytes: 100 * gb, availableBytes: 105 * gb).level == .low)
        #expect(SpaceCheck.evaluate(estimatedBytes: 10 * gb, availableBytes: nil).level == .ok)
    }

    @Test func messages() {
        #expect(SpaceCheck.evaluate(estimatedBytes: gb, availableBytes: 100 * gb).message == nil)
        let tooBig = SpaceCheck.evaluate(estimatedBytes: 300 * gb, availableBytes: 1000 * gb)
        #expect(tooBig.exceedsYouTubeLimit)
        #expect(tooBig.message?.contains("256 GB") == true)
        let full = SpaceCheck.evaluate(estimatedBytes: 10 * gb, availableBytes: gb)
        #expect(full.message?.hasPrefix("Not enough space") == true)
    }

    @Test func availableSpaceForAFolderThatDoesNotExistYet() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let notYet = folder.url.appendingPathComponent("a/b/c/video.mp4")
        let bytes = try #require(DiskSpace.availableBytes(for: notYet))
        #expect(bytes > 0)
    }
}

@Suite("OutputEstimate", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct OutputEstimateTests {
    /// The estimate should be within a few percent of a real export.
    @Test func matchesARealExport() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let clip = try await ClipInfo.load(from: VideoFixture.main.url)
        #expect(clip.videoByteCount > 0)
        let (asset, plan) = try await exportLoop(.main, seconds: 130, in: folder)
        let actual = try FileManager.default.attributesOfItem(atPath: asset.url.path)[.size] as? Int64 ?? 0
        let estimate = OutputEstimate.bytes(clip: clip, plan: plan)
        let ratio = Double(estimate) / Double(actual)
        #expect(ratio > 0.97 && ratio < 1.03, "estimate \(estimate) vs actual \(actual)")
    }
}
