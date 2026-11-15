import Foundation

/// One clip and the versions made from it (spec: "one clip → several versions").
/// Exported by `JobRunner` into:
///
///     <output folder>/<Clip name>/<Version name>/video.mp4
public struct Job: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var clip: URL
    public var versions: [Version]
    /// Time in the clip of the frame used for every version's thumbnail, seconds from
    /// the clip's start (picked by scrubbing, #46).
    public var thumbnailTime: Double
    /// The `Channel.id` whose branding the publish kit uses; nil for no channel.
    public var channelID: String?
    /// Scene, mood and elements for the channel templates.
    public var scene: SceneDetails

    public init(id: UUID = UUID(), clip: URL, versions: [Version] = [], thumbnailTime: Double = 0,
                channelID: String? = nil, scene: SceneDetails? = nil) {
        self.id = id
        self.clip = clip
        self.versions = versions
        self.thumbnailTime = thumbnailTime
        self.channelID = channelID
        self.scene = scene ?? SceneDetails(suggestedFor: clip)
    }

    private enum CodingKeys: String, CodingKey { case id, clip, versions, thumbnailTime, channelID, scene }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clip = try c.decode(URL.self, forKey: .clip)
        versions = try c.decodeIfPresent([Version].self, forKey: .versions) ?? []
        thumbnailTime = try c.decodeIfPresent(Double.self, forKey: .thumbnailTime) ?? 0
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
        scene = try c.decodeIfPresent(SceneDetails.self, forKey: .scene) ?? SceneDetails(suggestedFor: clip)
    }

    /// The folder holding all of this job's versions.
    public func folder(in outputFolder: URL) -> URL {
        outputFolder.appendingPathComponent(OutputLayout.folderName(forClip: clip), isDirectory: true)
    }

    /// Where `version` is written (before any "video 2.mp4" renaming).
    public func videoURL(for version: Version, in outputFolder: URL) -> URL {
        OutputLayout.videoURL(in: outputFolder, clip: clip, versionName: version.name)
    }

    /// Why the job can't be run as it is, or nil. Two versions with the same folder
    /// name would write into the same place.
    public var problem: JobError? {
        if versions.isEmpty { return .noVersions }
        var seen = Set<String>()
        for version in versions {
            // Finder folder names are case-insensitive by default.
            let key = version.folderName.lowercased()
            if !seen.insert(key).inserted { return .duplicateVersionName(version.folderName) }
        }
        return nil
    }
}

public enum JobError: Error, Equatable, LocalizedError {
    case noVersions
    case duplicateVersionName(String)

    public var errorDescription: String? {
        switch self {
        case .noVersions: "Add at least one version."
        case .duplicateVersionName(let name): "Two versions are named “\(name)”; each needs its own folder."
        }
    }
}
