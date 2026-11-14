import Darwin
import Foundation
import LooperCore

/// Command-line front end for the engine, used for benchmarks and the milestone
/// sign-off exports on real clips:
///
///     swift run -c release looper <clip> <duration> <output.mp4> [--bed <file>] [--playlist <folder>] [--clip-audio]
///
/// The bed can be an audio file or a video with sound; silence at its start and end is
/// trimmed (as in the app) unless `--keep-bed-silence` is given.
///
/// Prints progress, then wall time, peak memory and output size.
@main
struct LooperCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        var audio = LoopAudioSettings()
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let value = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return value
        }
        if let bed = option("--bed") { audio.bed = BedSettings(file: URL(fileURLWithPath: bed)) }
        if let folder = option("--playlist") { audio.playlist = PlaylistSettings(folder: URL(fileURLWithPath: folder)) }
        var trimBedSilence = true
        if let i = args.firstIndex(of: "--keep-bed-silence") {
            trimBedSilence = false
            args.remove(at: i)
        }
        if let i = args.firstIndex(of: "--clip-audio") {
            audio.clipAudio.enabled = true
            args.remove(at: i)
        }
        guard args.count == 3 else {
            log("usage: looper <clip> <duration: h:mm:ss | 8h | 45m> <output.mp4> [--bed <file>] [--keep-bed-silence] [--playlist <folder>] [--clip-audio]")
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

            if let bed = audio.bed {
                let item = try await AudioItem.load(from: bed.file)
                var line = "bed: \(bed.file.lastPathComponent), \(item.codec.trimmingCharacters(in: .whitespaces)), \(format(item.fileSeconds))"
                if let silence = try await SilenceTrim.detect(in: bed.file) {
                    let trimmed = String(format: "%.2f s at the start, %.2f s at the end",
                                         silence.start, item.fileSeconds - silence.end)
                    if trimBedSilence {
                        audio.bed?.trim = silence
                        line += "; trimmed silence: \(trimmed)"
                    } else {
                        line += "; silence kept: \(trimmed)"
                    }
                }
                log(line)
            }

            let clock = ContinuousClock()
            let start = clock.now
            let firstEstimate = EstimateRecorder()
            let hasAudio = audio.hasAudio(clipHasAudio: clip.hasAudio)
            if hasAudio {
                var parts: [String] = []
                if let bed = audio.bed { parts.append("bed \(bed.file.lastPathComponent)") }
                if let playlist = audio.playlist { parts.append("playlist \(playlist.folder.lastPathComponent)") }
                if audio.clipAudio.enabled && clip.hasAudio { parts.append("clip audio") }
                log("audio: " + parts.joined(separator: " + ") + " → AAC 48 kHz stereo")
            }
            try await LoopWriter().export(clip: clip, plan: plan, audio: hasAudio ? audio : nil,
                                          fileType: .mp4, to: outputURL, overwrite: true) { p in
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
