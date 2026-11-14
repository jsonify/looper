import AVFoundation
import Foundation
@testable import LooperCore

/// A fresh temporary folder for test outputs. Call `remove()` when done (use `defer`).
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("looper-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

enum TestEnvironment {
    static var longTests: Bool { ProcessInfo.processInfo.environment["LOOPER_LONG_TESTS"] == "1" }
}

/// Peak resident memory of the test process so far (macOS reports ru_maxrss in bytes).
func peakResidentBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

/// Exports `fixture` looped to `seconds` and returns the output asset and the plan.
func exportLoop(
    _ fixture: VideoFixture, seconds: Int, in folder: TemporaryFolder, name: String = "out.mp4",
    progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }
) async throws -> (asset: AVURLAsset, plan: LoopPlan) {
    let output = folder.file(name)
    let plan = try await LoopRenderer.render(
        clipURL: fixture.url, target: try TargetDuration(seconds: seconds), to: output, progress: progress)
    return (AVURLAsset(url: output, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]), plan)
}

/// True when every frame index follows the previous one, wrapping from N-1 to 0.
func isContinuousLoop(_ ids: [Int], frameCount: Int) -> Bool {
    zip(ids, ids.dropFirst()).allSatisfy { ($0 + 1) % frameCount == $1 }
}
