import AVFoundation

/// Decoded audio for assertions: the left channel at 48 kHz, as floats. Test-only.
struct DecodedAudio {
    static let sampleRate = 48_000.0
    /// Time of `samples[0]` in the track's timeline, seconds.
    let start: Double
    let samples: [Float]

    var duration: Double { Double(samples.count) / Self.sampleRate }

    static func decode(_ track: AVAssetTrack, in asset: AVAsset, timeRange: CMTimeRange? = nil) async throws -> DecodedAudio {
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
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
        guard reader.startReading() else { throw MediaInspectionError.readerFailed("\(String(describing: reader.error))") }
        var start: Double?
        var left: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            if start == nil { start = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
            let length = CMBlockBufferGetDataLength(block)
            var interleaved = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            interleaved.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            left.reserveCapacity(left.count + interleaved.count / 2)
            var i = 0
            while i < interleaved.count { left.append(interleaved[i]); i += 2 }
        }
        if reader.status == .failed { throw MediaInspectionError.readerFailed("\(String(describing: reader.error))") }
        return DecodedAudio(start: start ?? 0, samples: left)
    }

    /// Indices of samples between two times (relative to the track timeline).
    private func range(_ from: Double, _ to: Double) -> Range<Int> {
        let a = max(0, min(samples.count, Int(((from - start) * Self.sampleRate).rounded())))
        let b = max(a, min(samples.count, Int(((to - start) * Self.sampleRate).rounded())))
        return a..<b
    }

    func rms(from: Double, to: Double) -> Double {
        let r = range(from, to)
        guard !r.isEmpty else { return 0 }
        var sum = 0.0
        for i in r { sum += Double(samples[i]) * Double(samples[i]) }
        return (sum / Double(r.count)).squareRoot()
    }

    /// Rough dominant frequency from zero crossings (fine for pure tones).
    func frequency(from: Double, to: Double) -> Double {
        let r = range(from, to)
        guard r.count > 1 else { return 0 }
        var crossings = 0
        for i in r.dropFirst() where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(r.count) / Self.sampleRate)
    }
}

func decibels(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-9)) }
