import AVFoundation

/// The part of an audio file to use, in seconds of the file's own audio track.
public struct AudioTrim: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var length: Double { end - start }
}

/// Finds silence at the start and end of a recording, such as the moment before a
/// screen recording of a sound website starts playing. Left in, that gap would play
/// every time the bed wraps, so beds are trimmed to their audible part.
public enum SilenceTrim {
    /// Peaks below this are silence. -50 dBFS is well under any ambient bed and well
    /// above the noise floor of a digital recording.
    public static let thresholdDecibels = -50.0
    /// Peaks are measured in windows of this length.
    public static let windowSeconds = 0.01
    /// Trims shorter than this are ignored (not worth reporting or applying).
    public static let minimumTrim = 0.05

    /// The audible part of `url`'s first audio track, or nil when there is no silence
    /// worth trimming (or the whole file is silent, where trimming would leave nothing).
    public static func detect(in url: URL) async throws -> AudioTrim? {
        let (peaks, total) = try await windowPeaks(of: url)
        return audibleRange(windowPeaks: peaks, windowSeconds: windowSeconds, totalSeconds: total)
    }

    /// The trim for a run of per-window peaks (linear, 0...1). Pure, so it is tested
    /// without media.
    static func audibleRange(windowPeaks peaks: [Float], windowSeconds: Double, totalSeconds: Double,
                             thresholdDecibels: Double = thresholdDecibels) -> AudioTrim? {
        let threshold = Float(pow(10, thresholdDecibels / 20))
        guard let first = peaks.firstIndex(where: { $0 >= threshold }),
              let last = peaks.lastIndex(where: { $0 >= threshold }) else { return nil }
        let start = Double(first) * windowSeconds
        let end = min(totalSeconds, Double(last + 1) * windowSeconds)
        guard start >= minimumTrim || totalSeconds - end >= minimumTrim else { return nil }
        return AudioTrim(start: start >= minimumTrim ? start : 0,
                         end: totalSeconds - end >= minimumTrim ? end : totalSeconds)
    }

    /// Decodes the audio to float PCM and keeps only the peak of each window across all
    /// channels, so even an hour-long bed needs a few MB.
    static func windowPeaks(of url: URL) async throws -> (peaks: [Float], totalSeconds: Double) {
        let asset = AVURLAsset(url: url, options: ClipInfo.assetOptions)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioSourceError.noAudio(url.lastPathComponent)
        }
        let range = try await track.load(.timeRange)
        let sampleRate = LoopAudioSettings.sampleRate
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw AudioSourceError.unreadable(url.lastPathComponent, reader.error?.localizedDescription ?? "unknown error")
        }

        let framesPerWindow = Int(sampleRate * windowSeconds)
        var peaks: [Float] = []
        var currentPeak: Float = 0
        var framesInWindow = 0
        var buffer: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let length = CMBlockBufferGetDataLength(block)
            buffer = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            buffer.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            var i = 0
            while i < buffer.count {
                for c in 0..<channels where i + c < buffer.count {
                    currentPeak = max(currentPeak, abs(buffer[i + c]))
                }
                i += channels
                framesInWindow += 1
                if framesInWindow == framesPerWindow {
                    peaks.append(currentPeak)
                    currentPeak = 0
                    framesInWindow = 0
                }
            }
        }
        if framesInWindow > 0 { peaks.append(currentPeak) }
        if reader.status == .failed {
            throw AudioSourceError.unreadable(url.lastPathComponent, reader.error?.localizedDescription ?? "unknown error")
        }
        return (peaks, range.duration.seconds)
    }
}
