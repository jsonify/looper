import Foundation

/// The title patterns and hook lines a channel's recent uploads used, so the next upload
/// picks different ones (YouTube's repetitive content policy). Stored as `history.json`
/// in the channel's folder.
///
/// Entries are keyed by job and version. When a version's kit is made again (Regenerate),
/// its own entry and everything recorded after it are ignored, so the same seed gives the
/// same text; recording replaces the old entry.
public struct ChannelHistory: Codable, Equatable, Sendable {
    public struct Upload: Codable, Equatable, Sendable {
        /// "<job id>/<version id>".
        public var key: String
        public var date: Date
        public var titlePattern: String
        public var hook: String

        public init(key: String, date: Date = Date(), titlePattern: String, hook: String) {
            self.key = key
            self.date = date
            self.titlePattern = titlePattern
            self.hook = hook
        }
    }

    public static let fileName = "history.json"
    /// How many recent uploads' choices a new kit avoids.
    public static let recentWindow = 5
    /// Older entries are dropped when saving.
    public static let keptUploads = 200

    /// Oldest first.
    public var uploads: [Upload]

    public init(uploads: [Upload] = []) {
        self.uploads = uploads
    }

    public static func key(job: Job, version: Version) -> String { "\(job.id.uuidString)/\(version.id.uuidString)" }

    /// The uploads a kit for `key` should look at: those before its own entry, if any.
    func uploads(before key: String) -> ArraySlice<Upload> {
        if let index = uploads.firstIndex(where: { $0.key == key }) { return uploads[..<index] }
        return uploads[...]
    }

    /// Adds or replaces the entry for `upload.key`, keeping its place if it had one.
    public mutating func record(_ upload: Upload) {
        if let index = uploads.firstIndex(where: { $0.key == upload.key }) {
            uploads[index] = upload
        } else {
            uploads.append(upload)
        }
        if uploads.count > Self.keptUploads { uploads.removeFirst(uploads.count - Self.keptUploads) }
    }

    /// An empty history when the file doesn't exist yet.
    public static func load(from url: URL) throws -> ChannelHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return ChannelHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChannelHistory.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension LoadedChannel {
    /// Where this channel's history is kept.
    public var historyURL: URL { folder.appendingPathComponent(ChannelHistory.fileName) }
}

extension KitRandom {
    /// Picks from `candidates`, preferring ones not used in the recent window of `used`
    /// (most recent last). If all were used recently, takes the one used longest ago.
    mutating func pick(_ candidates: [String], avoiding used: [String]) -> String? {
        let recent = Set(used.suffix(ChannelHistory.recentWindow))
        let fresh = candidates.filter { !recent.contains($0) }
        if !fresh.isEmpty { return pick(fresh) }
        return candidates.min { (used.lastIndex(of: $0) ?? -1) < (used.lastIndex(of: $1) ?? -1) }
    }
}
