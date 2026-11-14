import AVFoundation
import Testing
@testable import LooperCore

/// #21: a real 8 h export from the tiny clip: duration, seams near start, middle and
/// end, memory and speed. Runs when LOOPER_LONG_TESTS=1 (CI on main, manual runs).
@Suite("Long export", .enabled(if: Fixtures.available && TestEnvironment.longTests,
                               "Set LOOPER_LONG_TESTS=1 and generate fixtures to run"))
struct LongExportTests {
    @Test func eightHoursFromTheTinyClip() async throws {
        let fixture = VideoFixture.tiny
        let folder = try TemporaryFolder()
        defer { folder.remove() }

        let memoryBefore = peakResidentBytes()
        let clock = ContinuousClock()
        let started = clock.now
        let (asset, plan) = try await exportLoop(fixture, seconds: 8 * 3600, in: folder)
        let elapsed = clock.now - started
        let memoryAfter = peakResidentBytes()
        let size = try FileManager.default.attributesOfItem(atPath: asset.url.path)[.size] as? Int64 ?? 0
        print("8 h export: \(elapsed), output \(size / 1_000_000) MB, peak RSS \(memoryBefore / 1_000_000) → \(memoryAfter / 1_000_000) MB")

        #expect(plan.frameCount == 8 * 3600 * 30)
        #expect(try await MediaInspection.videoSampleCount(of: asset) == plan.frameCount)
        let track = try await MediaInspection.videoTrack(of: asset)
        let timeRange = try await track.load(.timeRange)
        #expect(abs((timeRange.duration - plan.duration).seconds) < 1e-6)

        // Seams after the first copy, in the middle and the last one.
        for copy in [1, 480, 959] {
            let seam = plan.clipDuration * Int32(copy)
            let window = CMTimeRange(start: seam - plan.frameDuration * 5, duration: plan.frameDuration * 10)
            let ids = try await MediaInspection.frameIDs(of: asset, bitBlock: fixture.bitBlock, timeRange: window)
            #expect(ids.contains(0) && ids.contains(899), "seam \(copy): \(ids)")
            #expect(isContinuousLoop(ids, frameCount: fixture.frameCount), "seam \(copy): \(ids)")
        }

        // Memory should stay flat: passthrough streams samples instead of holding them.
        #expect(memoryAfter - memoryBefore < 500_000_000)
    }
}
