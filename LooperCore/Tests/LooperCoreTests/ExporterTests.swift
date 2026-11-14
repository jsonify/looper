import AVFoundation
import Testing
@testable import LooperCore

@Suite("PassthroughExporter", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct ExporterTests {
    @Test func refusesToOverwriteUnlessAsked() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let output = folder.file("video.mp4")
        try Data("existing".utf8).write(to: output)
        let target = try TargetDuration(seconds: 5)

        await #expect(throws: ExportError.outputExists(output)) {
            try await LoopRenderer.render(clipURL: VideoFixture.tiny.url, target: target, to: output)
        }
        #expect(try Data(contentsOf: output) == Data("existing".utf8))

        try await LoopRenderer.render(clipURL: VideoFixture.tiny.url, target: target, to: output, overwrite: true)
        let clip = try await ClipInfo.load(from: output)
        #expect(clip.frameCount == 150)
        #expect(try folder.contents() == ["video.mp4"])
    }

    @Test func reportsMonotonicProgressEndingAtOne() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let log = ProgressLog()
        _ = try await exportLoop(.tiny, seconds: 3600, in: folder) { log.append($0) }
        let fractions = log.values.map(\.fractionCompleted)
        #expect(fractions.last == 1)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "\(fractions)")
    }

    @Test func cancellingStopsTheExportAndLeavesNoFiles() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let output = folder.file("video.mp4")
        let started = AsyncStream<Void>.makeStream()

        let export = Task {
            try await LoopRenderer.render(clipURL: VideoFixture.main.url, target: .eightHours, to: output) { p in
                if p.fractionCompleted > 0 { started.continuation.yield() }
            }
        }
        // Cancel as soon as the export has visibly started.
        for await _ in started.stream { break }
        export.cancel()

        let result = await export.result
        #expect(throws: CancellationError.self) { try result.get() }
        let leftovers = try folder.contents()
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExportProgress] = []
    func append(_ value: ExportProgress) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [ExportProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

extension TemporaryFolder {
    /// File names in the folder, including hidden ones (such as partial exports).
    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}
