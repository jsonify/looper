import Foundation

/// One upload made from a job's clip, such as "8h Sleep" or "3h Study": its length,
/// its audio mix, an optional fade to black and the publish-kit templates.
///
/// Codable so presets (#41) can store versions as JSON. Decoding fills in defaults for
/// the optional parts (fade, publish kit, audio), so older or hand-written files still
/// load as the format grows.
public struct Version: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Shown in the app and used as the output folder name: `<Clip name>/<name>/`.
    public var name: String
    /// What the upload is for, e.g. "Sleep", "Study", "Focus": picks the channel's
    /// per-mode text. Older files without it take it from the name ("8h Sleep" → "Sleep").
    public var mode: String
    /// False turns the channel's No-Ads label off for this version only, e.g. when its
    /// ads stay on for revenue. Ignored when the channel doesn't use the label.
    public var noAds: Bool
    public var duration: TargetDuration
    /// Bed, playlist and clip audio, each with its own volume and fades.
    public var audio: LoopAudioSettings
    public var videoFade: VideoFade
    public var publish: PublishTemplates

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        mode: String? = nil,
        noAds: Bool = true,
        duration: TargetDuration,
        audio: LoopAudioSettings = LoopAudioSettings(),
        videoFade: VideoFade = .off,
        publish: PublishTemplates = PublishTemplates()
    ) {
        self.id = id
        let name = name ?? OutputLayout.versionName(for: duration)
        self.name = name
        self.mode = mode ?? Self.mode(fromName: name)
        self.noAds = noAds
        self.duration = duration
        self.audio = audio
        self.videoFade = videoFade
        self.publish = publish
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mode, noAds, duration, audio, videoFade, publish
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try c.decode(TargetDuration.self, forKey: .duration)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? OutputLayout.versionName(for: duration)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? Self.mode(fromName: name)
        noAds = try c.decodeIfPresent(Bool.self, forKey: .noAds) ?? true
        audio = try c.decodeIfPresent(LoopAudioSettings.self, forKey: .audio) ?? LoopAudioSettings()
        videoFade = try c.decodeIfPresent(VideoFade.self, forKey: .videoFade) ?? .off
        publish = try c.decodeIfPresent(PublishTemplates.self, forKey: .publish) ?? PublishTemplates()
    }

    /// The folder this version is written to inside the clip's folder.
    public var folderName: String { OutputLayout.safeName(name) }

    /// "8h Sleep" → "Sleep", "1h30m Deep Focus" → "Deep Focus", "3h" → "": the name
    /// without a leading duration.
    static func mode(fromName name: String) -> String {
        var words = name.split(separator: " ").map(String.init)
        if let first = words.first, first.lowercased().wholeMatch(of: /(\d+h)?(\d+m)?(\d+s)?/) != nil {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }
}

/// Fade the picture to black over the last `seconds` of the video. Stored now, rendered
/// once the tail re-encode lands (#43, #44).
public struct VideoFade: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var seconds: Double

    public static let defaultSeconds = 30.0
    public static let off = VideoFade(enabled: false)

    public init(enabled: Bool, seconds: Double = defaultSeconds) {
        self.enabled = enabled
        self.seconds = seconds
    }
}

/// Per-version overrides for the channel's publish kit (`KitFactory`). Empty fields use
/// the channel's pools. Placeholders such as `{scene}` and `{duration}` work as in the
/// channel's templates.
public struct PublishTemplates: Codable, Equatable, Sendable {
    /// Used as the title pattern instead of one from the channel's pool; " (No-Ads)" is
    /// still added when the label is on.
    public var title: String
    /// Used as the description's opening (hook) line instead of one from the pool; the
    /// rest of the description still comes from the channel.
    public var description: String
    /// Extra tags, ranked with the scene tags (highest priority).
    public var tags: [String]
    public var thumbnail: ThumbnailStyle

    public init(title: String = "", description: String = "", tags: [String] = [],
                thumbnail: ThumbnailStyle = ThumbnailStyle()) {
        self.title = title
        self.description = description
        self.tags = tags
        self.thumbnail = thumbnail
    }

    private enum CodingKeys: String, CodingKey { case title, description, tags, thumbnail }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        thumbnail = try c.decodeIfPresent(ThumbnailStyle.self, forKey: .thumbnail) ?? ThumbnailStyle()
    }
}

/// How the thumbnail looks. The spec allows one fixed layout (big hours number plus a
/// mode label, #47), so the only choices are whether to draw it, the label and a colour.
public struct ThumbnailStyle: Codable, Equatable, Sendable {
    /// Draw the hours and mode text on the picked frame.
    public var showsText: Bool
    /// The mode label, e.g. "Sleep" or "Study". Empty uses the version name.
    public var modeLabel: String
    /// Text colour as "#RRGGBB".
    public var color: String

    public static let defaultColor = "#FFFFFF"

    public init(showsText: Bool = false, modeLabel: String = "", color: String = defaultColor) {
        self.showsText = showsText
        self.modeLabel = modeLabel
        self.color = color
    }

    private enum CodingKeys: String, CodingKey { case showsText, modeLabel, color }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showsText = try c.decodeIfPresent(Bool.self, forKey: .showsText) ?? false
        modeLabel = try c.decodeIfPresent(String.self, forKey: .modeLabel) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? Self.defaultColor
    }
}

/// Stored as whole seconds; decoding runs the same checks as `init(seconds:)`, so a
/// file can't smuggle in a zero or over-12-hour duration. Hand-written files (channels)
/// may also use text such as "3h" or "1:30:00".
extension TargetDuration: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            if let text = try? container.decode(String.self) {
                try self.init(parsing: text)
            } else {
                try self.init(seconds: try container.decode(Int.self))
            }
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: error.localizedDescription)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(seconds)
    }
}
