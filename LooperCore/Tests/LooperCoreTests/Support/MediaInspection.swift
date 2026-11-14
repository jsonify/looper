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

    /// Decodes frames and returns the frame index drawn into each one, in presentation
    /// order (see `FrameID`). Pass `timeRange` to decode only part of the asset.
    static func frameIDs(of asset: AVAsset, bitBlock: Int, timeRange: CMTimeRange? = nil) async throws -> [Int] {
        let track = try await videoTrack(of: asset)
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
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

    /// Presentation times of all video samples, sorted, read without decoding.
    static func videoPresentationTimes(of asset: AVAsset) async throws -> [CMTime] {
        try await compressedVideoSamples(of: asset) { sample in
            CMSampleBufferGetPresentationTimeStamp(sample)
        }.sorted { $0 < $1 }
    }

    /// A hash of each compressed video sample's bytes, in decode order. Equal hashes
    /// between output and source mean the samples were copied, not re-encoded.
    static func videoSampleHashes(of asset: AVAsset) async throws -> [Int] {
        try await compressedVideoSamples(of: asset) { sample in
            guard let block = CMSampleBufferGetDataBuffer(sample) else { return 0 }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            var hasher = Hasher()
            hasher.combine(bytes)
            return hasher.finalize()
        }
    }

    private static func compressedVideoSamples<T>(
        of asset: AVAsset, _ transform: (CMSampleBuffer) -> T
    ) async throws -> [T] {
        let track = try await videoTrack(of: asset)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw failure(reader) }
        var results: [T] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            results.append(transform(sample))
        }
        if reader.status == .failed { throw failure(reader) }
        return results
    }

    /// Codec, sample rate and channel count of an audio track.
    static func audioFormat(of track: AVAssetTrack) async throws -> (codec: String, sampleRate: Double, channels: Int) {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return ("?", 0, 0)
        }
        let code = CMFormatDescriptionGetMediaSubType(description)
        let codec = String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
        return (codec, asbd.mSampleRate, Int(asbd.mChannelsPerFrame))
    }

    /// RMS level of an audio track (decoded to 48 kHz stereo float) inside each window,
    /// given in seconds of track time.
    static func audioRMS(of track: AVAssetTrack, in asset: AVAsset, windows: [ClosedRange<Double>]) async throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 48_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw failure(reader) }
        var sums = [Double](repeating: 0, count: windows.count)
        var counts = [Int](repeating: 0, count: windows.count)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            floats.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            for (index, value) in floats.enumerated() {
                let time = start + Double(index / 2) / sampleRate
                for (w, window) in windows.enumerated() where window.contains(time) {
                    sums[w] += Double(value) * Double(value)
                    counts[w] += 1
                }
            }
        }
        if reader.status == .failed { throw failure(reader) }
        return zip(sums, counts).map { $1 > 0 ? ($0 / Double($1)).squareRoot() : 0 }
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
