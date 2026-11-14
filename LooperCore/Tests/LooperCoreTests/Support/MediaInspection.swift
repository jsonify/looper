import AVFoundation
import CoreVideo

enum MediaInspectionError: Error {
    case noVideoTrack
    case readerFailed(String)
}

/// Helpers that read media back for assertions. Test-only.
enum MediaInspection {
    static func videoTrack(of asset: AVAsset) async throws -> AVAssetTrack {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaInspectionError.noVideoTrack
        }
        return track
    }

    /// Number of video samples, counted without decoding.
    static func videoSampleCount(of asset: AVAsset) async throws -> Int {
        let track = try await videoTrack(of: asset)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw failure(reader) }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
        }
        if reader.status == .failed { throw failure(reader) }
        return count
    }

    /// Decodes every frame and returns the frame index drawn into each one, in
    /// presentation order (see `FrameID`).
    static func frameIDs(of asset: AVAsset, bitBlock: Int) async throws -> [Int] {
        let track = try await videoTrack(of: asset)
        let reader = try AVAssetReader(asset: asset)
        // Full-range 4:2:0 gives direct access to an 8-bit luma plane.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw failure(reader) }
        var ids: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            ids.append(FrameID.decode(pixels, bitBlock: bitBlock))
        }
        if reader.status == .failed { throw failure(reader) }
        return ids
    }

    private static func failure(_ reader: AVAssetReader) -> Error {
        reader.error ?? MediaInspectionError.readerFailed("status \(reader.status.rawValue)")
    }
}

/// Reads the frame index that `scripts/make-test-clip.sh` draws into every frame:
/// 16 square blocks along the top-left edge, block 0 = least significant bit,
/// white = 1, black = 0.
enum FrameID {
    static let bitCount = 16

    static func decode(_ pixels: CVPixelBuffer, bitBlock: Int) -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return -1 }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let y = bitBlock / 2
        var value = 0
        for bit in 0..<bitCount {
            // Sample the centre of each block, well away from compression edges.
            let x = bit * bitBlock + bitBlock / 2
            if luma[y * bytesPerRow + x] > 128 { value |= 1 << bit }
        }
        return value
    }
}
