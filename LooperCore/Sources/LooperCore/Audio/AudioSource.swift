import AVFoundation

/// One audio file Looper can use: a bed, or a song in a playlist.
public struct AudioItem: Sendable, Equatable {
    public let url: URL
    public let seconds: Double
    /// Four-character codec, e.g. "lpcm", "flac", "aac ".
    public let codec: String
    public let sampleRate: Double
    public let channels: Int

    /// Lossless inputs are preferred: the mix is encoded to AAC once, and starting from
    /// an already-lossy file means a second generation of compression.
    public var isLossless: Bool { ["lpcm", "flac", "alac"].contains(codec) }

    public var name: String { url.lastPathComponent }

    public static func load(from url: URL) async throws -> AudioItem {
        let asset = AVURLAsset(url: url, options: ClipInfo.assetOptions)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioSourceError.unreadable(url.lastPathComponent, error.localizedDescription)
        }
        guard let track = tracks.first else { throw AudioSourceError.noAudio(url.lastPathComponent) }
        let (timeRange, formats) = try await track.load(.timeRange, .formatDescriptions)
        guard timeRange.duration.seconds > 0 else { throw AudioSourceError.empty(url.lastPathComponent) }
        let description = formats.first
        let asbd = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        return AudioItem(
            url: url,
            seconds: timeRange.duration.seconds,
            codec: description.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?",
            sampleRate: asbd?.mSampleRate ?? 0,
            channels: Int(asbd?.mChannelsPerFrame ?? 0))
    }
}

public enum AudioSourceError: Error, Equatable, LocalizedError {
    case unreadable(String, String)
    case noAudio(String)
    case empty(String)
    case emptyFolder(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name, let reason): "“\(name)” couldn't be read: \(reason)"
        case .noAudio(let name): "“\(name)” has no audio."
        case .empty(let name): "“\(name)” is empty."
        case .emptyFolder(let name): "The folder “\(name)” has no audio files."
        }
    }
}

/// Where a track's audio comes from. Looper reads files made elsewhere (Suno, Mirelo,
/// recordings) and works offline; a generator could conform later without touching the
/// mixing or export code (see docs/plans/looper-spec.md).
public protocol AudioSource: Sendable {
    /// The audio files in play order.
    func items() async throws -> [AudioItem]
}

/// A single file, e.g. the ambient bed.
public struct FileAudioSource: AudioSource {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func items() async throws -> [AudioItem] { [try await AudioItem.load(from: url)] }
}

/// Every audio file in a folder, in Finder's name order ("2 song" before "10 song").
/// Hidden files and subfolders are ignored; unreadable files are reported, not skipped.
public struct FolderAudioSource: AudioSource {
    public static let fileExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "m4a", "mp3", "aac"]

    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    public func audioFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                 options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            .filter { Self.fileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public func items() async throws -> [AudioItem] {
        let files = try audioFiles()
        guard !files.isEmpty else { throw AudioSourceError.emptyFolder(folder.lastPathComponent) }
        var items: [AudioItem] = []
        for file in files { items.append(try await AudioItem.load(from: file)) }
        return items
    }
}
