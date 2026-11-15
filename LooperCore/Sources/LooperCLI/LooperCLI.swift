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
/// With `--channel <folder or channel.json>`, the channel's publish kit text is made too
/// (`title.txt`, `description.txt`, `tags.txt` next to the output) and printed:
///
///     --scene "Rainy Log Cabin" --mood cozy --elements "rain, fireplace" [--mode Sleep]
///     [--seed <n>] [--record-history]
///
/// The scene defaults to one made from the clip's file name, the mode to the channel's
/// default version of the same length (or its first). The channel's history is read so
/// choices avoid recent uploads, but only written with `--record-history`, so test runs
/// don't count as uploads.
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
        let channelPath = option("--channel")
        let scene = option("--scene"), mood = option("--mood"), elements = option("--elements")
        let mode = option("--mode"), seed = option("--seed")
        var recordHistory = false
        if let i = args.firstIndex(of: "--record-history") {
            recordHistory = true
            args.remove(at: i)
        }
        guard args.count == 3, seed.map({ UInt64($0) != nil }) ?? true else {
            log("usage: looper <clip> <duration: h:mm:ss | 3h | 45m> <output.mp4> [--bed <file>] [--keep-bed-silence] "
                + "[--playlist <folder>] [--clip-audio] [--channel <folder> [--scene <text>] [--mood <text>] "
                + "[--elements <a, b, c>] [--mode <mode>] [--seed <number>] [--record-history]]")
            exit(2)
        }
        let clipURL = URL(fileURLWithPath: args[0])
        let outputURL = URL(fileURLWithPath: args[2])

        do {
            let target = try TargetDuration(parsing: args[1])

            // The kit is made before exporting, so a template problem shows at once.
            var kitRun: (loaded: LoadedChannel, kit: PublishKit)?
            if let channelPath {
                var folder = URL(fileURLWithPath: channelPath)
                if folder.pathExtension == "json" { folder.deleteLastPathComponent() }
                let loaded = try ChannelLibrary.loadChannel(at: folder)
                let channel = loaded.channel
                let defaults = channel.versions.first { $0.duration == target } ?? channel.versions.first
                let version = Version(mode: mode ?? defaults?.mode, noAds: defaults?.noAds ?? true,
                                      duration: target, audio: audio)
                var details = SceneDetails(suggestedFor: clipURL)
                if let scene { details.scene = scene }
                if let mood { details.mood = mood }
                if let elements {
                    details.elements = elements.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let job = Job(clip: clipURL, versions: [version], channelID: channel.id, scene: details,
                              kitSeed: seed.flatMap(UInt64.init))
                let history = try ChannelHistory.load(from: loaded.historyURL)
                let kit = try KitFactory(channel: channel).kit(for: version, in: job, history: history)
                kitRun = (loaded, kit)
                log("channel: \(channel.name), mode \(version.mode), scene “\(details.scene)”, seed \(job.kitSeed)")
            }
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

            if let (loaded, kit) = kitRun {
                let folder = outputURL.deletingLastPathComponent()
                try kit.write(to: folder)
                if recordHistory {
                    var history = try ChannelHistory.load(from: loaded.historyURL)
                    history.record(kit.historyEntry)
                    try history.save(to: loaded.historyURL)
                }
                log("")
                log("title (\(kit.title.count) chars): \(kit.title)")
                log("")
                log("description (\(kit.description.count) chars):\n\(kit.description)")
                log("")
                log("tags (\(kit.tags.count)): \(kit.tagsText)")
                for note in kit.notes { log("note: \(note)") }
                log("kit: \(PublishKit.titleFileName), \(PublishKit.descriptionFileName), \(PublishKit.tagsFileName) in \(folder.path)"
                    + (recordHistory ? "; recorded in the channel's history" : ""))
            }
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
