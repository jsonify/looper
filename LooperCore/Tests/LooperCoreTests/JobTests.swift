import CoreMedia
import Foundation
import Testing
@testable import LooperCore

/// A clip made up in memory: 30 s at 30 fps. The runner tests need no fixtures.
func fakeClip(url: URL = URL(fileURLWithPath: "/clips/cabin rain.mp4"), hasAudio: Bool = false) -> ClipInfo {
    ClipInfo(
        url: url,
        videoTimeRange: CMTimeRange(start: .zero, duration: CMTime(value: 900, timescale: 30)),
        timescale: 30, frameDuration: CMTime(value: 1, timescale: 30), nominalFrameRate: 30,
        frameCount: 900, naturalSize: CGSize(width: 320, height: 180), preferredTransform: .identity,
        codec: "avc1", estimatedDataRate: 100_000, isConstantFrameRate: true, hasAudio: hasAudio,
        videoByteCount: 375_000)
}

/// Records each export and behaves per output folder name.
final class RecordingExporter: LoopExporting, @unchecked Sendable {
    enum Behaviour: Sendable { case succeed, fail, waitForCancel }
    struct Call: Sendable { let url: URL; let frames: Int; let hasAudio: Bool }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let behaviours: [String: Behaviour]

    init(_ behaviours: [String: Behaviour] = [:]) { self.behaviours = behaviours }

    var calls: [Call] { lock.withLock { _calls } }

    func export(clip: ClipInfo, plan: LoopPlan, audio: LoopAudioSettings?, to outputURL: URL, overwrite: Bool,
                progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        lock.withLock { _calls.append(Call(url: outputURL, frames: plan.frameCount, hasAudio: audio != nil)) }
        progress(ExportProgress(fractionCompleted: 0.5, estimatedTimeRemaining: nil))
        switch behaviours[outputURL.deletingLastPathComponent().lastPathComponent] ?? .succeed {
        case .succeed:
            try Data("video".utf8).write(to: outputURL)
            progress(ExportProgress(fractionCompleted: 1, estimatedTimeRemaining: 0))
        case .fail:
            throw ExportError.failed("boom")
        case .waitForCancel:
            try await Task.sleep(for: .seconds(60))
        }
    }
}

final class JobProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [JobProgress] = []
    func append(_ p: JobProgress) { lock.withLock { _items.append(p) } }
    var items: [JobProgress] { lock.withLock { _items } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

@Suite("Job and Version model")
struct JobModelTests {
    func sampleJob() throws -> Job {
        let sleep = Version(
            name: "8h Sleep", duration: .eightHours,
            audio: LoopAudioSettings(
                bed: BedSettings(file: URL(fileURLWithPath: "/audio/rain.wav"),
                                 trim: AudioTrim(start: 0.8, end: 9.5),
                                 track: AudioTrackSettings(volume: 0.4, fadeIn: 10, fadeOut: 120)),
                playlist: PlaylistSettings(folder: URL(fileURLWithPath: "/audio/piano", isDirectory: true), crossfade: 4),
                clipAudio: ClipAudioSettings(enabled: true)),
            videoFade: VideoFade(enabled: true, seconds: 45),
            publish: PublishTemplates(
                title: "{hours} Hours of {scene} for {mode}", description: "Relax.\n\n{tracklist}",
                tags: ["sleep", "rain"], thumbnail: ThumbnailStyle(showsText: true, modeLabel: "Sleep", color: "#88AAFF")))
        let study = Version(name: "3h Study", duration: .threeHours)
        return Job(clip: URL(fileURLWithPath: "/clips/cabin rain.mp4"), versions: [sleep, study], thumbnailTime: 12.5)
    }

    @Test func jobRoundTripsThroughJSON() throws {
        let job = try sampleJob()
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        #expect(decoded == job)
    }

    @Test func durationIsStoredAsSeconds() throws {
        let data = try JSONEncoder().encode(Version(duration: try TargetDuration(hours: 1, seconds: 10)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["duration"] as? Int == 3610)
        #expect(object["name"] as? String == "1h0m10s")
    }

    @Test func invalidDurationIsRejected() {
        for seconds in [0, 13 * 3600] {
            let json = Data(#"{"duration": \#(seconds)}"#.utf8)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(Version.self, from: json) }
        }
    }

    @Test func missingOptionalPartsGetDefaults() throws {
        let version = try JSONDecoder().decode(Version.self, from: Data(#"{"duration": 10800}"#.utf8))
        #expect(version.name == "3h")
        #expect(version.duration == .threeHours)
        #expect(version.audio == LoopAudioSettings())
        #expect(version.videoFade == .off)
        #expect(version.publish == PublishTemplates())

        let job = try JSONDecoder().decode(Job.self, from: Data(#"{"clip": "file:///clips/a.mp4"}"#.utf8))
        #expect(job.versions.isEmpty)
        #expect(job.thumbnailTime == 0)
        #expect(job.clip.path == "/clips/a.mp4")
    }

    @Test func versionsMustHaveDistinctFolders() throws {
        var job = try sampleJob()
        #expect(job.problem == nil)
        job.versions.append(Version(name: "8H SLEEP", duration: .oneHour))
        #expect(job.problem == .duplicateVersionName("8H SLEEP"))
        job.versions = []
        #expect(job.problem == .noVersions)
    }

    @Test func outputFollowsTheSpecLayout() throws {
        let job = try sampleJob()
        let root = URL(fileURLWithPath: "/out", isDirectory: true)
        #expect(job.videoURL(for: job.versions[0], in: root).path == "/out/cabin rain/8h Sleep/video.mp4")
        #expect(job.folder(in: root).path == "/out/cabin rain")
    }
}

@Suite("JobRunner")
struct JobRunnerTests {
    func runner(_ exporter: RecordingExporter, hasAudio: Bool = false) -> JobRunner {
        JobRunner(exporter: exporter, loadClip: { fakeClip(url: $0, hasAudio: hasAudio) })
    }

    func job(_ versions: [Version]) -> Job {
        Job(clip: URL(fileURLWithPath: "/clips/cabin rain.mp4"), versions: versions)
    }

    @Test func exportsEachVersionInOrderIntoItsFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let exporter = RecordingExporter()
        let loads = Counter()
        let runner = JobRunner(exporter: exporter, loadClip: {
            loads.increment()
            return fakeClip(url: $0)
        })
        let log = JobProgressLog()
        let result = try await runner.run(
            job([Version(name: "1h Study", duration: .oneHour),
                 Version(name: "8h Sleep", duration: .eightHours),
                 Version(duration: try TargetDuration(seconds: 3610))]),
            outputFolder: folder.url, progress: { log.append($0) })

        #expect(loads.value == 1, "the clip is loaded once for all versions")
        let names = exporter.calls.map { $0.url.deletingLastPathComponent().lastPathComponent }
        #expect(names == ["1h Study", "8h Sleep", "1h0m10s"])
        #expect(exporter.calls.map(\.frames) == [108_000, 864_000, 108_300])
        #expect(exporter.calls.allSatisfy { $0.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "cabin rain" })
        #expect(result.outcomes == exporter.calls.map { VersionOutcome.finished($0.url) })
        #expect(!result.wasCancelled)

        let overall = log.items.map(\.overall.fractionCompleted)
        #expect(zip(overall, overall.dropFirst()).allSatisfy { $0 <= $1 }, "overall progress never goes back")
        #expect(overall.last == 1)
        #expect(log.items.map(\.versionIndex) == log.items.map(\.versionIndex).sorted())
        // Weighted by length: half of the 1 h version is 0.5 / 10 of the 10 h (plus 10 s) job.
        let halfFirst = try #require(log.items.first { $0.versionIndex == 0 && $0.version.fractionCompleted == 0.5 })
        #expect(abs(halfFirst.overall.fractionCompleted - 1800.0 / (3600 + 28_800 + 3610)) < 1e-9)
    }

    @Test func audioIsPassedOnlyWhenTheVersionHasSome() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let exporter = RecordingExporter()
        let withClipAudio = Version(name: "a", duration: .oneHour,
                                    audio: LoopAudioSettings(clipAudio: ClipAudioSettings(enabled: true)))
        _ = try await runner(exporter, hasAudio: false).run(job([withClipAudio]), outputFolder: folder.url)
        _ = try await runner(exporter, hasAudio: true).run(job([withClipAudio]), outputFolder: folder.url)
        #expect(exporter.calls.map(\.hasAudio) == [false, true])
    }

    @Test func failureIsRecordedAndTheRestStillRun() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let exporter = RecordingExporter(["bad": .fail])
        let result = try await runner(exporter).run(
            job([Version(name: "bad", duration: .oneHour), Version(name: "good", duration: .oneHour)]),
            outputFolder: folder.url)
        #expect(result.outcomes.count == 2)
        #expect(result.outcomes[0] == .failed(ExportError.failed("boom").localizedDescription))
        guard case .finished = result.outcomes[1] else { Issue.record("\(result.outcomes[1])"); return }
    }

    @Test func cancelStopsTheCurrentVersionAndSkipsTheRest() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let exporter = RecordingExporter(["slow": .waitForCancel])
        let log = JobProgressLog()
        let jobRunner = runner(exporter)
        let task = Task {
            try await jobRunner.run(
                job([Version(name: "first", duration: .oneHour), Version(name: "slow", duration: .oneHour),
                     Version(name: "never", duration: .oneHour)]),
                outputFolder: folder.url, progress: { log.append($0) })
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !log.items.contains(where: { $0.versionIndex == 1 && $0.version.fractionCompleted == 0.5 }) {
            guard clock.now < deadline else { Issue.record("slow version never started"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        let result = try await task.value
        #expect(result.outcomes.count == 3)
        guard case .finished = result.outcomes[0] else { Issue.record("\(result.outcomes[0])"); return }
        #expect(Array(result.outcomes.dropFirst()) == [.cancelled, .skipped])
        #expect(result.wasCancelled)
        #expect(exporter.calls.count == 2, "the version after the cancel never starts")
    }

    @Test func existingVideoIsKeptUnlessReplacing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let exporter = RecordingExporter()
        let theJob = job([Version(name: "8h", duration: .eightHours)])
        let destination = theJob.videoURL(for: theJob.versions[0], in: folder.url)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)

        let kept = try await runner(exporter).run(theJob, outputFolder: folder.url)
        #expect(kept.finishedURLs.map(\.lastPathComponent) == ["video 2.mp4"])
        #expect(try Data(contentsOf: destination) == Data("old".utf8))

        let replaced = try await runner(exporter).run(theJob, outputFolder: folder.url, replacing: true)
        #expect(replaced.finishedURLs == [destination])
        #expect(try Data(contentsOf: destination) == Data("video".utf8))
    }

    @Test func invalidJobThrowsBeforeExporting() async throws {
        let exporter = RecordingExporter()
        await #expect(throws: JobError.noVersions) {
            try await runner(exporter).run(job([]), outputFolder: URL(fileURLWithPath: "/tmp"))
        }
        #expect(exporter.calls.isEmpty)
    }
}
