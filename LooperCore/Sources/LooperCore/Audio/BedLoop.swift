import AVFoundation
import CryptoKit

/// A short bed rendered once with its wrap crossfade baked in, so it can repeat on one
/// composition track with no volume ramps per wrap.
///
/// Why: laid out as a chain (`AudioChain`), every wrap needs about 20 volume ramps, and
/// `AVMutableAudioMixInputParameters.setVolumeRamp` checks each new ramp against every
/// ramp already on the track. That cost grows with the square of the ramp count: a 10 s
/// bed took 11 s to set up for 1 h and about 11 min for 8 h, in the preview (on every
/// level change) and in the export.
///
/// The rendered file is `x[0..<P] ++ blend` where `x` is the bed (length `L`), `c` the
/// overlap, `P = L - c`, and `blend = x[P..<L]·fadeOut + x[0..<c]·fadeIn` (the chain's
/// equal-power curves). Playing the whole file once and then its part from `c` to the
/// end over and over gives exactly the chain's sound, with every crossfade in the same
/// place. The file is written in one pass over the bed, so every boundary between
/// repeats joins samples that were adjacent in the source: nothing can click.
struct BedLoop {
    /// Beds up to this long are rendered (at most ~115 MB of float samples on disk).
    /// Longer beds wrap rarely enough that their ramps are cheap, so they stay a chain.
    static let maxRenderedSeconds = 300.0
    static let sampleRate = 48_000.0

    let url: URL
    /// Whole file length, overlap and repeat period, in 48 kHz frames.
    let frames: Int64
    let overlapFrames: Int64
    var periodFrames: Int64 { frames - overlapFrames }

    /// The overlap the chain would use for a single item: never more than half of it.
    static func overlap(itemSeconds: Double, crossfade: Double) -> Double {
        min(max(crossfade, 0), itemSeconds / 2)
    }

    /// Output frame ranges to insert: (start in the file, length, output start).
    func segments(totalFrames: Int64) -> [(from: Int64, length: Int64, at: Int64)] {
        var result: [(from: Int64, length: Int64, at: Int64)] = []
        guard frames > 0, periodFrames > 0 else { return result }
        result.append((0, min(frames, totalFrames), 0))
        var at = frames
        while at < totalFrames {
            result.append((overlapFrames, min(periodFrames, totalFrames - at), at))
            at += periodFrames
        }
        return result
    }

    /// Renders `item` (its trimmed part) with an overlap of `overlapSeconds`, reusing an
    /// earlier render of the same file, part and overlap.
    static func render(item: AudioItem, overlapSeconds: Double) async throws -> BedLoop {
        let frames = Int64((item.seconds * sampleRate).rounded(.down))
        let overlapFrames = Int64((overlapSeconds * sampleRate).rounded(.down))
        let url = cacheURL(item: item, overlapFrames: overlapFrames)
        let loop = BedLoop(url: url, frames: frames, overlapFrames: overlapFrames)
        if FileManager.default.fileExists(atPath: url.path) { return loop }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await write(item: item, frames: Int(frames), overlap: Int(overlapFrames), to: temp)
        // Another build may have finished the same render meanwhile; either copy is fine.
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: temp, to: url)
        }
        return loop
    }

    private static func cacheURL(item: AudioItem, overlapFrames: Int64) -> URL {
        let modified = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(item.url.path)|\(modified)|\(item.start)|\(item.seconds)|\(overlapFrames)"
        let name = Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LooperBedLoops", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name).appendingPathExtension("caf")
    }

    /// One pass over the bed: keep its first `overlap` frames, write frames up to `P`
    /// as they come, then write the tail blended with the kept head.
    private static func write(item: AudioItem, frames: Int, overlap: Int, to url: URL) async throws {
        let asset = AVURLAsset(url: item.url, options: ClipInfo.assetOptions)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioSourceError.noAudio(item.name)
        }
        let trackStart = try await track.load(.timeRange).start
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: trackStart + CMTime(seconds: item.start, preferredTimescale: 48_000),
                                       duration: CMTime(seconds: item.seconds, preferredTimescale: 48_000))
        // The mix output converts any source (mono, 44.1 kHz, AAC from a video) to the
        // export's 48 kHz stereo float.
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw AudioSourceError.unreadable(item.name, reader.error?.localizedDescription ?? "can't read")
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false) else {
            throw AudioSourceError.unreadable(item.name, "no 48 kHz stereo format")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let period = frames - overlap
        var head: [Float] = []           // interleaved, first `overlap` frames
        head.reserveCapacity(overlap * 2)
        var position = 0                 // source frames consumed

        func emit(_ samples: UnsafeBufferPointer<Float>, from start: Int) throws {
            // `samples` holds interleaved frames starting at source frame `start`.
            let count = samples.count / 2
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channels = buffer.floatChannelData else { return }
            for i in 0..<count {
                var l = samples[2 * i], r = samples[2 * i + 1]
                let frame = start + i
                if frame >= period {
                    // Tail: crossfade out, with the head crossfading in underneath.
                    let u = frame - period
                    let x = (Double(u) + 0.5) / Double(overlap)
                    let fadeOut = Float(GainEnvelope.fadeOutCurve(x)), fadeIn = Float(GainEnvelope.fadeInCurve(x))
                    l = l * fadeOut + head[2 * u] * fadeIn
                    r = r * fadeOut + head[2 * u + 1] * fadeIn
                }
                channels[0][i] = l
                channels[1][i] = r
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
        }

        while position < frames, let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            // Copy out: a block buffer isn't always contiguous.
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == noErr else { continue }
            let available = min(samples.count / 2, frames - position)
            let headCount = max(0, min(overlap - position, available))
            if headCount > 0 { head += samples[0..<(headCount * 2)] }
            try samples.withUnsafeBufferPointer { all in
                try emit(UnsafeBufferPointer(rebasing: all[0..<(available * 2)]), from: position)
            }
            position += available
        }
        if reader.status == .failed {
            throw AudioSourceError.unreadable(item.name, reader.error?.localizedDescription ?? "read failed")
        }
        reader.cancelReading()
        // A source a few frames short of its stated length: pad with silence so the file
        // has exactly `frames` and every repeat lands where the chain would put it.
        if position < frames {
            let padding = [Float](repeating: 0, count: (frames - position) * 2)
            if head.count < overlap * 2 { head += [Float](repeating: 0, count: overlap * 2 - head.count) }
            try padding.withUnsafeBufferPointer { try emit($0, from: position) }
        }
    }
}
