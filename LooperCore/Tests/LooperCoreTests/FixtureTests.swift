import AVFoundation
import Testing

/// Checks that the generated fixtures are what the engine tests assume, and that
/// the frame-identity decoding the seam tests rely on works under AVFoundation.
@Suite("Fixtures")
struct FixtureTests {
    @Test("Fixtures exist (required in CI)")
    func fixturesPresent() {
        if Fixtures.required {
            #expect(Fixtures.available, "Missing fixtures in \(Fixtures.directory.path). Run scripts/make-test-clip.sh.")
        }
    }

    @Test(.enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"),
          arguments: VideoFixture.all)
    func videoFixtureShape(_ fixture: VideoFixture) async throws {
        let asset = AVURLAsset(url: fixture.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try #require(videoTracks.count == 1)
        #expect(audioTracks.count == (fixture.hasAudio ? 1 : 0))

        let (size, frameRate, minFrameDuration) = try await videoTracks[0].load(
            .naturalSize, .nominalFrameRate, .minFrameDuration)
        #expect(Int(size.width) == fixture.width)
        #expect(Int(size.height) == fixture.height)
        #expect(abs(Double(frameRate) - fixture.framesPerSecond) < 0.01)
        let expectedFrameDuration = CMTime(
            value: fixture.frameDurationValue, timescale: fixture.frameDurationTimescale)
        #expect(minFrameDuration == expectedFrameDuration)

        let samples = try await MediaInspection.videoSampleCount(of: asset)
        #expect(samples == fixture.frameCount)
    }

    @Test(.enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"),
          arguments: VideoFixture.all)
    func frameIDsRunInOrder(_ fixture: VideoFixture) async throws {
        let asset = AVURLAsset(url: fixture.url)
        let ids = try await MediaInspection.frameIDs(of: asset, bitBlock: fixture.bitBlock)
        #expect(ids == Array(0..<fixture.frameCount))
    }

    @Test(.enabled(if: Fixtures.available, "Run scripts/make-test-clip.sh to generate fixtures"),
          arguments: AudioFixture.all)
    func audioFixtureShape(_ fixture: AudioFixture) async throws {
        let asset = AVURLAsset(url: fixture.url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try #require(tracks.count == 1)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - fixture.seconds) < 0.05)

        let descriptions = try await tracks[0].load(.formatDescriptions)
        let format = try #require(descriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        })
        #expect(format.mSampleRate == 48_000)
        #expect(format.mChannelsPerFrame == 2)
    }
}
