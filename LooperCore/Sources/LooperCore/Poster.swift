import AVFoundation

/// A still frame for showing the clip in the UI.
public struct PosterImage: @unchecked Sendable {
    // @unchecked: CGImage is immutable once created.
    public let cgImage: CGImage

    /// The clip's first frame, scaled to fit `maxPixelSize`.
    public static func firstFrame(of url: URL, maxPixelSize: CGFloat = 640) async throws -> PosterImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let (image, _) = try await generator.image(at: .zero)
        return PosterImage(cgImage: image)
    }
}
