import AVFoundation
import Testing
@testable import LooperCore

/// #20: an 8 h composition (960 inserts) has every copy exactly where it should be.
/// No export, so it runs on every push.
@Suite("Drift", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct DriftTests {
    @Test(arguments: [VideoFixture.main, .fps2997])
    func eightHourCompositionHasExactInsertTimes(_ fixture: VideoFixture) async throws {
        let clip = try await ClipInfo.load(from: fixture.url)
        let plan = LoopPlan(clip: clip, target: .eightHours)
        let clock = ContinuousClock()
        let started = clock.now
        let loop = try await LoopComposer.compose(clip: clip, plan: plan)
        print("composed \(plan.copyCount) copies of \(fixture.name) in \(clock.now - started)")

        #expect(loop.insertTimes.count == plan.copyCount)
        for (index, time) in loop.insertTimes.enumerated() {
            #expect(time == clip.duration.multiplied(by: index), "copy \(index) starts at \(time.seconds)")
        }

        // Segments are contiguous: each starts exactly where the previous one ended.
        let segments = loop.videoTrack.segments.filter { !$0.isEmpty }
        #expect(segments.count == plan.copyCount)
        var end = CMTime.zero
        for (index, segment) in segments.enumerated() {
            let target = segment.timeMapping.target
            #expect(target.start == end, "segment \(index) starts at \(target.start.seconds), expected \(end.seconds)")
            end = target.end
        }
        #expect(end == plan.duration)
        let duration = try await loop.composition.load(.duration)
        #expect(duration == plan.duration)
        if fixture.frameDurationTimescale == 30 {
            #expect(plan.duration == CMTime(value: 8 * 3600, timescale: 1))
        }
    }
}
