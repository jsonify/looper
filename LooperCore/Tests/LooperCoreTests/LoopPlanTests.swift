import CoreMedia
import Testing
@testable import LooperCore

@Suite("TargetDuration")
struct TargetDurationTests {
    @Test(arguments: [
        ("1:00:10", 3610), ("8:00:00", 28800), ("0:30", 30), ("90:00", 5400),
        ("8h", 28800), ("3H", 10800), ("45m", 2700), (" 1:02:03 ", 3723), ("12:00:00", 43200),
    ])
    func parses(_ text: String, _ seconds: Int) throws {
        #expect(try TargetDuration(parsing: text).seconds == seconds)
    }

    @Test(arguments: ["", "abc", "1:60:00", "1:00:60", "1::00", "1:2:3:4", "-1:00", "h", "1.5h", "١:٠٠"])
    func rejectsMalformed(_ text: String) {
        #expect(throws: TargetDurationError.malformed(text)) { try TargetDuration(parsing: text) }
    }

    @Test func rejectsZeroAndOverTwelveHours() {
        #expect(throws: TargetDurationError.zero) { try TargetDuration(parsing: "0:00:00") }
        #expect(throws: TargetDurationError.tooLong(43201)) { try TargetDuration(parsing: "12:00:01") }
    }

    @Test func formatsAsHMMSS() throws {
        #expect(try TargetDuration(parsing: "1:00:10").description == "1:00:10")
        #expect(TargetDuration.eightHours.description == "8:00:00")
    }
}

@Suite("LoopPlan")
struct LoopPlanTests {
    // A 30 s clip at 30 fps with ffmpeg's usual MP4 timescale (15360).
    let clip30 = (duration: CMTime(value: 30 * 15360, timescale: 15360),
                  frame: CMTime(value: 512, timescale: 15360), frames: 900)

    @Test func threeHoursIsExactly360CopiesAnd324000Frames() {
        let plan = LoopPlan(clipDuration: clip30.duration, frameDuration: clip30.frame,
                            clipFrameCount: clip30.frames, target: .threeHours)
        #expect(plan.fullCopies == 360)
        #expect(plan.remainderFrames == 0)
        #expect(plan.copyCount == 360)
        #expect(plan.frameCount == 324_000)
        #expect(plan.duration == CMTime(value: 3 * 3600, timescale: 1))
    }

    @Test func eightHoursIs960Copies() {
        let plan = LoopPlan(clipDuration: clip30.duration, frameDuration: clip30.frame,
                            clipFrameCount: clip30.frames, target: .eightHours)
        #expect(plan.fullCopies == 960)
        #expect(plan.insertTimes.count == 960)
        #expect(plan.insertTimes.last == CMTime(value: 959 * 30, timescale: 1))
    }

    @Test func nonMultipleTargetTrimsTheLastCopy() throws {
        let plan = LoopPlan(clipDuration: clip30.duration, frameDuration: clip30.frame,
                            clipFrameCount: clip30.frames, target: try TargetDuration(parsing: "1:00:10"))
        #expect(plan.fullCopies == 120)
        #expect(plan.remainderFrames == 300)
        #expect(plan.remainder == CMTime(value: 10, timescale: 1))
        #expect(plan.remainder.timescale == 15360)
        #expect(plan.copyCount == 121)
        #expect(plan.frameCount == 108_300)
        #expect(plan.duration == CMTime(value: 3610, timescale: 1))
    }

    @Test func targetShorterThanOneClip() throws {
        let plan = LoopPlan(clipDuration: clip30.duration, frameDuration: clip30.frame,
                            clipFrameCount: clip30.frames, target: try TargetDuration(seconds: 10))
        #expect(plan.fullCopies == 0)
        #expect(plan.remainderFrames == 300)
        #expect(plan.copyCount == 1)
        #expect(plan.insertTimes == [.zero])
    }

    @Test func twentyFourFPS() throws {
        let plan = LoopPlan(clipDuration: CMTime(value: 30 * 12288, timescale: 12288),
                            frameDuration: CMTime(value: 512, timescale: 12288),
                            clipFrameCount: 720, target: try TargetDuration(parsing: "1:00:10"))
        #expect(plan.frameCount == 3610 * 24)
        #expect(plan.fullCopies == 120)
        #expect(plan.remainderFrames == 240)
    }

    @Test func ntscRateRoundsDownToTheLastWholeFrame() {
        // 900 frames at 30000/1001 fps = 30.03 s.
        let frame = CMTime(value: 1001, timescale: 30000)
        let plan = LoopPlan(clipDuration: frame.multiplied(by: 900), frameDuration: frame,
                            clipFrameCount: 900, target: .oneHour)
        // 3600 × 30000 / 1001 = 107892.1 → 107892 frames.
        #expect(plan.frameCount == 107_892)
        #expect(plan.fullCopies == 119)
        #expect(plan.remainderFrames == 792)
        #expect(plan.duration == frame.multiplied(by: 107_892))
        #expect(plan.duration <= CMTime(value: 3600, timescale: 1))
        #expect(CMTime(value: 3600, timescale: 1) - plan.duration < frame)
    }
}

@Suite("ETAEstimator")
struct ETAEstimatorTests {
    @Test func hiddenUntilEnoughProgress() {
        var eta = ETAEstimator()
        #expect(eta.update(fraction: 0.01, elapsed: 10) == nil)
        #expect(eta.update(fraction: 0.5, elapsed: 1) == nil)
    }

    @Test func linearFromAverageRate() throws {
        var eta = ETAEstimator()
        let value = try #require(eta.update(fraction: 0.25, elapsed: 30))
        #expect(abs(value - 90) < 0.001)
        #expect(eta.update(fraction: 1, elapsed: 120) == 0)
    }
}
