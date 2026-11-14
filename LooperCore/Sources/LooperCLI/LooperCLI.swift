import Darwin
import Foundation
import LooperCore

/// Command-line front end for the engine, used for benchmarks and the milestone
/// sign-off exports on real clips:
///
///     swift run -c release looper <clip> <duration> <output.mp4>
///
/// Prints progress, then wall time, peak memory and output size.
@main
struct LooperCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else {
            log("usage: looper <clip> <duration: h:mm:ss | 8h | 45m> <output.mp4>")
            exit(2)
        }
        let clipURL = URL(fileURLWithPath: args[0])
        let outputURL = URL(fileURLWithPath: args[2])

        do {
            let target = try TargetDuration(parsing: args[1])
            let clip = try await ClipInfo.load(from: clipURL)
            let plan = LoopPlan(clip: clip, target: target)
            log("clip: \(Int(clip.naturalSize.width))x\(Int(clip.naturalSize.height)) \(clip.codec), "
                + "\(clip.nominalFrameRate) fps, \(clip.frameCount) frames, \(format(clip.duration.seconds))"
                + (clip.isConstantFrameRate ? "" : " (variable frame rate)"))
            log("plan: \(target) = \(plan.fullCopies) full copies + \(plan.remainderFrames) frames, "
                + "\(plan.frameCount) frames, \(format(plan.duration.seconds))")

            let clock = ContinuousClock()
            let start = clock.now
            let firstEstimate = EstimateRecorder()
            try await LoopRenderer.render(clipURL: clipURL, target: target, to: outputURL, overwrite: true) { p in
                let percent = String(format: "%5.1f%%", p.fractionCompleted * 100)
                let eta = p.estimatedTimeRemaining.map { "about \(format($0)) left" } ?? "estimating…"
                if let remaining = p.estimatedTimeRemaining, p.fractionCompleted < 1 {
                    firstEstimate.record(remaining: remaining, at: clock.now - start)
                }
                logInline("\(percent)  \(eta)")
            }
            let elapsed = clock.now - start
            log("")

            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            log("done in \(elapsed.formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))")
            if let estimate = firstEstimate.value {
                let (remaining, at) = estimate
                let predictedTotal = at.seconds + remaining
                log("first time-remaining estimate (at \(format(at.seconds))): total \(format(predictedTotal))")
            }
            log("peak memory: \(ByteCountFormatter.string(fromByteCount: peakResidentBytes(), countStyle: .memory))")
            log("output: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) at \(outputURL.path)")
        } catch {
            log("")
            log("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func logInline(_ line: String) {
        FileHandle.standardError.write(Data(("\r" + line + "   ").utf8))
    }

    /// Peak resident memory of this process (macOS reports ru_maxrss in bytes).
    static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }
}

/// Keeps the first time-remaining estimate, to compare with the real time afterwards.
final class EstimateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var first: (TimeInterval, Duration)?

    func record(remaining: TimeInterval, at elapsed: Duration) {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = (remaining, elapsed) }
    }

    var value: (TimeInterval, Duration)? {
        lock.lock(); defer { lock.unlock() }
        return first
    }
}

extension Duration {
    var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }
}
