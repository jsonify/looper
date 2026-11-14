import AVFoundation
import Testing
@testable import LooperCore

@Suite("ClipInfo", .enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"))
struct ClipInfoTests {
    @Test(arguments: VideoFixture.all)
    func loadsFixture(_ fixture: VideoFixture) async throws {
        let clip = try await ClipInfo.load(from: fixture.url)
        #expect(clip.frameCount == fixture.frameCount)
        #expect(clip.frameDuration == CMTime(value: fixture.frameDurationValue, timescale: fixture.frameDurationTimescale))
        #expect(clip.duration == clip.frameDuration.multiplied(by: fixture.frameCount))
        #expect(Int(clip.naturalSize.width) == fixture.width)
        #expect(Int(clip.naturalSize.height) == fixture.height)
        #expect(clip.codec == "avc1")
        #expect(clip.isConstantFrameRate)
        #expect(clip.hasAudio == fixture.hasAudio)
        #expect(clip.estimatedDataRate > 0)
    }

    @Test func rejectsANonVideoFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fake = folder.file("not-a-video.mp4")
        try Data("hello".utf8).write(to: fake)
        await #expect(throws: ClipError.self) { try await ClipInfo.load(from: fake) }
    }

    @Test func rejectsAnAudioOnlyFile() async throws {
        await #expect(throws: ClipError.noVideoTrack) { try await ClipInfo.load(from: AudioFixture.bed.url) }
    }

    @Test func rejectsAMissingFile() async {
        let missing = Fixtures.url("does-not-exist.mp4")
        await #expect(throws: ClipError.self) { try await ClipInfo.load(from: missing) }
    }
}
