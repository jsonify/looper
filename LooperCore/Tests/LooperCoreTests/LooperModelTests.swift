import Foundation
import Testing
@testable import LooperCore

/// A stand-in exporter for testing the model's state machine.
struct FakeExporter: LoopExporting {
    enum Behaviour: Sendable { case succeed, fail, waitForCancel }
    let behaviour: Behaviour

    func export(clip: ClipInfo, plan: LoopPlan, audio: LoopAudioSettings?, to outputURL: URL, overwrite: Bool,
                progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        progress(ExportProgress(fractionCompleted: 0.5, estimatedTimeRemaining: 1))
        switch behaviour {
        case .succeed: try Data("video".utf8).write(to: outputURL)
        case .fail: throw ExportError.failed("boom")
        case .waitForCancel: try await Task.sleep(for: .seconds(60))
        }
    }
}

@MainActor
@Suite("LooperModel", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct LooperModelTests {
    func makeModel(exporter: any LoopExporting = FakeExporter(behaviour: .succeed),
                   space: Int64? = 1_000_000_000_000, folder: TemporaryFolder) -> LooperModel {
        let defaults = UserDefaults(suiteName: "looper-tests-\(UUID().uuidString)")!
        let model = LooperModel(defaults: defaults, exporter: exporter, availableSpace: { _ in space })
        model.outputFolder = folder.url
        return model
    }

    func waitWhileExporting(_ model: LooperModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while model.isExporting {
            guard clock.now < deadline else { Issue.record("export didn't finish"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func startsBlockedUntilAClipIsLoaded() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(folder: folder)
        #expect(!model.canExport)
        #expect(model.exportBlockedReason == "Choose a loop clip.")
    }

    @Test func loadingAClipFillsInThePlanAndOutput() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(folder: folder)
        await model.loadClip(from: VideoFixture.tiny.url)
        #expect(model.clip?.frameCount == 900)
        #expect(model.poster != nil)
        #expect(model.clipError == nil)
        #expect(model.planSummary?.hasPrefix("960 copies") == true)
        #expect(model.outputURL?.path.hasSuffix("loop-tiny30/8h/video.mp4") == true)
        #expect(model.canExport)
    }

    @Test func badClipShowsAnError() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(folder: folder)
        await model.loadClip(from: AudioFixture.bed.url)
        #expect(model.clip == nil)
        #expect(model.clipError != nil)
    }

    @Test func customDurationIsValidated() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(folder: folder)
        await model.loadClip(from: VideoFixture.tiny.url)
        model.durationChoice = .custom
        model.customDuration = "1:00:10"
        #expect(model.planSummary?.hasPrefix("120 copies + 0:00:10") == true)
        #expect(model.outputURL?.path.hasSuffix("/1h0m10s/video.mp4") == true)
        model.customDuration = "nope"
        #expect(model.targetError != nil)
        #expect(!model.canExport)
        #expect(model.exportBlockedReason == model.targetError)
    }

    @Test func notEnoughSpaceBlocksTheExport() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(space: 1_000, folder: folder)
        await model.loadClip(from: VideoFixture.tiny.url)
        #expect(model.spaceCheck?.level == .insufficient)
        #expect(model.exportBlockedReason?.hasPrefix("Not enough space") == true)
    }

    @Test func successfulExportFinishesWithTheFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(folder: folder)
        await model.loadClip(from: VideoFixture.tiny.url)
        model.startExport()
        #expect(model.isExporting)
        #expect(!model.canExport)
        try await waitWhileExporting(model)
        let expected = try #require(model.outputURL)
        #expect(model.phase == .finished(expected))
        #expect(model.progress?.fractionCompleted == 1)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test func existingFileIsKeptUnlessReplacing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(folder: folder)
        await model.loadClip(from: VideoFixture.tiny.url)
        let destination = try #require(model.outputURL)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        #expect(model.outputExists)

        model.startExport(replacing: false)
        try await waitWhileExporting(model)
        #expect(model.phase == .finished(destination.deletingLastPathComponent().appendingPathComponent("video 2.mp4")))
        #expect(try Data(contentsOf: destination) == Data("old".utf8))

        model.startExport(replacing: true)
        try await waitWhileExporting(model)
        #expect(model.phase == .finished(destination))
        #expect(try Data(contentsOf: destination) == Data("video".utf8))
    }

    @Test func failureIsReported() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(exporter: FakeExporter(behaviour: .fail), folder: folder)
        await model.loadClip(from: VideoFixture.tiny.url)
        model.startExport()
        try await waitWhileExporting(model)
        guard case .failed(let message) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(message.contains("boom"))
        model.dismissResult()
        #expect(model.phase == .idle)
    }

    @Test func cancelStopsTheExport() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(exporter: FakeExporter(behaviour: .waitForCancel), folder: folder)
        await model.loadClip(from: VideoFixture.tiny.url)
        model.startExport()
        while (model.progress?.fractionCompleted ?? 0) < 0.5 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.exportElapsed != nil)
        model.cancelExport()
        try await waitWhileExporting(model)
        #expect(model.phase == .cancelled)
    }

    @Test func remembersTheOutputFolder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let defaults = UserDefaults(suiteName: "looper-tests-\(UUID().uuidString)")!
        let first = LooperModel(defaults: defaults, exporter: FakeExporter(behaviour: .succeed))
        first.outputFolder = folder.url
        let second = LooperModel(defaults: defaults, exporter: FakeExporter(behaviour: .succeed))
        #expect(second.outputFolder?.standardizedFileURL == folder.url.standardizedFileURL)
    }

    @Test func audioChoicesFeedTheExport() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(folder: folder)
        await model.loadClip(from: VideoFixture.tiny.url)
        let silentEstimate = try #require(model.estimatedBytes)
        #expect(model.exportAudio == nil)

        await model.chooseBed(AudioFixture.bed.url)
        #expect(model.bedItem?.name == "bed.wav")
        #expect(model.audio.bed?.file == AudioFixture.bed.url)
        #expect(model.audioNotes.contains { $0.contains("repetition") }) // 10 s bed
        await model.choosePlaylist(Fixtures.url(AudioFixture.playlistDirectory))
        #expect(model.playlistItems.count == 3)
        #expect(model.playlistSummary?.hasPrefix("3 songs · 0:00:18") == true)
        #expect(model.exportAudio != nil)
        // 8 h of 256 kbps AAC ≈ 921.6 MB on top of the video.
        let withAudio = try #require(model.estimatedBytes)
        #expect(withAudio - silentEstimate == Int64(256_000.0 / 8 * 8 * 3600))

        model.removeBed()
        model.removePlaylist()
        #expect(model.exportAudio == nil)

        await model.chooseBed(VideoFixture.tiny.url) // no audio track
        #expect(model.audioError != nil)
        #expect(model.audio.bed == nil)
    }

    @Test func clipAudioCountsOnlyWhenTheClipHasAudio() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(folder: folder)
        model.audio.clipAudio.enabled = true
        await model.loadClip(from: VideoFixture.tiny.url)
        #expect(model.exportAudio == nil)
        await model.loadClip(from: VideoFixture.withAudio.url)
        #expect(model.exportAudio != nil)
    }

    /// End to end with the real writer.
    @Test func realExportWithLoopWriter() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let model = makeModel(exporter: LoopWriter(), folder: folder)
        await model.loadClip(from: VideoFixture.tiny.url)
        model.durationChoice = .custom
        model.customDuration = "0:45"
        model.startExport()
        try await waitWhileExporting(model)
        let output = try #require(model.outputURL)
        #expect(model.phase == .finished(output))
        let exported = try await ClipInfo.load(from: output)
        #expect(exported.frameCount == 45 * 30)
    }
}
