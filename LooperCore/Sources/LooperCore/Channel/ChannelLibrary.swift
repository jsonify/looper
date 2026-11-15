import Foundation

/// A channel read from disk, with the files that sit beside its `channel.json`.
public struct LoadedChannel: Equatable, Sendable {
    public var channel: Channel
    /// The channel's own folder.
    public var folder: URL
    /// `logo.png` in the channel's folder, if there is one.
    public var logoURL: URL?

    /// `channel.defaultPlaylist` resolved: absolute, `~/…`, or relative to `folder`.
    public var defaultPlaylistURL: URL? {
        guard let path = channel.defaultPlaylist?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL }
        return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: folder).standardizedFileURL
    }
}

/// The channels in a folder, one subfolder per channel:
///
///     <Channels>/
///       rainfall-hours/  channel.json  logo.png
///       quiet-keys/      channel.json
///
/// A broken channel doesn't hide the others: it's listed in `failures` with the reason.
public struct ChannelLibrary: Equatable, Sendable {
    public static let fileName = "channel.json"
    public static let logoFileName = "logo.png"

    public struct Failure: Equatable, Sendable {
        public var folder: URL
        public var message: String
    }

    /// Valid channels, sorted by name.
    public var channels: [LoadedChannel]
    public var failures: [Failure]

    public func channel(id: String) -> LoadedChannel? { channels.first { $0.channel.id == id } }

    /// Reads every subfolder of `root` that holds a `channel.json`. Throws only if `root`
    /// itself can't be read.
    public static func load(from root: URL, fileManager: FileManager = .default) throws -> ChannelLibrary {
        let folders = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent(fileName).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var channels: [LoadedChannel] = []
        var failures: [Failure] = []
        for folder in folders {
            do {
                let loaded = try loadChannel(at: folder, fileManager: fileManager)
                if channels.contains(where: { $0.channel.id == loaded.channel.id }) {
                    failures.append(Failure(folder: folder, message: "Another channel already uses the id “\(loaded.channel.id)”."))
                } else {
                    channels.append(loaded)
                }
            } catch {
                failures.append(Failure(folder: folder, message: Self.message(for: error)))
            }
        }
        channels.sort { $0.channel.name.localizedStandardCompare($1.channel.name) == .orderedAscending }
        return ChannelLibrary(channels: channels, failures: failures)
    }

    /// Reads and validates the channel in `folder`.
    public static func loadChannel(at folder: URL, fileManager: FileManager = .default) throws -> LoadedChannel {
        let data = try Data(contentsOf: folder.appendingPathComponent(fileName))
        let channel = try JSONDecoder().decode(Channel.self, from: data)
        try channel.validate()
        let logo = folder.appendingPathComponent(logoFileName)
        return LoadedChannel(channel: channel, folder: folder,
                             logoURL: fileManager.fileExists(atPath: logo.path) ? logo : nil)
    }

    /// A readable reason, including where in the JSON a decoding error is.
    static func message(for error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return keys.isEmpty ? "" : " at \(keys.hasPrefix(".") ? String(keys.dropFirst()) : keys)"
        }
        switch decoding {
        case .keyNotFound(let key, let context): return "\(fileName) is missing “\(key.stringValue)”\(path(context))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(fileName) has a problem\(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }
}
