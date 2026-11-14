import Foundation

/// Reads exported files with ffmpeg/ffprobe, as a second opinion next to AVFoundation.
/// YouTube's ingest is ffmpeg-like, so the output must decode the same way there:
/// in particular the multi-segment edit lists a looped passthrough export produces.
///
/// Tests using it are skipped when ffmpeg isn't installed, unless
/// `LOOPER_REQUIRE_FFMPEG=1` (set in CI) turns that into a failure.
enum FFmpeg {
    static let ffmpeg = locate("ffmpeg")
    static let ffprobe = locate("ffprobe")

    static var available: Bool { ffmpeg != nil && ffprobe != nil }
    static var required: Bool { ProcessInfo.processInfo.environment["LOOPER_REQUIRE_FFMPEG"] == "1" }

    enum Failure: Error { case missing, exited(Int32), unparsable(String) }

    static func locate(_ name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Decoded video frame count, as ffprobe reports it (after applying edit lists).
    static func frameCount(of url: URL) throws -> Int {
        guard let ffprobe else { throw Failure.missing }
        let output = try run(ffprobe, ["-v", "error", "-count_frames", "-select_streams", "v:0",
                                       "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", url.path])
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(text) else { throw Failure.unparsable(text) }
        return count
    }

    /// Frame indices of every decoded frame (see `FrameID`), decoded by ffmpeg.
    static func frameIDs(of url: URL, bitBlock: Int) throws -> [Int] {
        guard let ffmpeg else { throw Failure.missing }
        let width = bitBlock * FrameID.bitCount
        let height = bitBlock
        let raw = try run(ffmpeg, ["-v", "error", "-i", url.path,
                                   "-vf", "crop=\(width):\(height):0:0,format=gray",
                                   "-f", "rawvideo", "-"])
        let frameSize = width * height
        return raw.withUnsafeBytes { bytes in
            stride(from: 0, to: raw.count - frameSize + 1, by: frameSize).map { start in
                var value = 0
                for bit in 0..<FrameID.bitCount {
                    let offset = start + (bitBlock / 2) * width + bit * bitBlock + bitBlock / 2
                    if bytes[offset] > 128 { value |= 1 << bit }
                }
                return value
            }
        }
    }

    private static func run(_ tool: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.exited(process.terminationStatus) }
        return data
    }
}
