import Foundation

/// A YouTube channel's brand kit: how its uploads are titled, described, tagged and
/// thumbnailed, and which versions a new job on it starts with (spec: "Channels and
/// branding factory").
///
/// Stored as `channel.json` in the channel's own folder (see `ChannelLibrary`) and edited
/// by hand for now, so decoding is forgiving: optional parts get defaults, pools may be a
/// plain list, and durations may be written as "3h". `ChannelValidation` then catches
/// mistakes (unknown placeholders, bad colours, missing pools) when the channel loads.
public struct Channel: Codable, Equatable, Sendable {
    /// Stable reference used by jobs, e.g. "rainfall-hours". Unique within a library.
    public var id: String
    /// Shown in the app and available to templates as `{channel}`.
    public var name: String
    public var brand: ChannelBrand
    /// Append " (No-Ads)" to titles and lead descriptions with "(No-Ads)". A version can
    /// still turn it off (`Version.noAds`).
    public var noAds: Bool
    /// Title patterns, e.g. "{scene} | {duration} of Rain Sounds for Sleep".
    public var titles: ModePools
    /// First line of the description.
    public var hooks: ModePools
    /// "What you hear" line, e.g. "You'll hear {elements}." Optional: when a pool is empty
    /// or its placeholders are empty for a job, the section is left out.
    public var hear: ModePools
    /// "Perfect for…" line.
    public var perfectFor: ModePools
    /// Mode-specific tags such as "sleep sounds" (after the scene tags, before core tags).
    public var modeTags: ModePools
    /// Fixed text after the generated sections: subscribe line, links, music/AI credit.
    public var footer: String
    /// Up to three; YouTube shows the first three above the title.
    public var hashtags: [String]
    /// Tags every upload on the channel gets, lowest priority.
    public var coreTags: [String]
    /// Versions a new job on this channel starts with.
    public var versions: [Version]
    /// Music folder for new jobs: absolute, `~/…`, or relative to the channel's folder.
    public var defaultPlaylist: String?
    /// How templates name the music, as in a sentence, e.g. "soft piano": `{music}`.
    /// Only versions with a playlist fill it; for others `{music}` is empty.
    public var music: String

    public init(id: String, name: String, brand: ChannelBrand = ChannelBrand(), noAds: Bool = true,
                titles: ModePools = ModePools(), hooks: ModePools = ModePools(), hear: ModePools = ModePools(),
                perfectFor: ModePools = ModePools(), modeTags: ModePools = ModePools(), footer: String = "",
                hashtags: [String] = [], coreTags: [String] = [], versions: [Version] = [],
                defaultPlaylist: String? = nil, music: String = "") {
        self.id = id
        self.name = name
        self.brand = brand
        self.noAds = noAds
        self.titles = titles
        self.hooks = hooks
        self.hear = hear
        self.perfectFor = perfectFor
        self.modeTags = modeTags
        self.footer = footer
        self.hashtags = hashtags
        self.coreTags = coreTags
        self.versions = versions
        self.defaultPlaylist = defaultPlaylist
        self.music = music
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, brand, noAds, titles, hooks, hear, perfectFor, modeTags, footer, hashtags, coreTags,
             versions, defaultPlaylist, music
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        brand = try c.decodeIfPresent(ChannelBrand.self, forKey: .brand) ?? ChannelBrand()
        noAds = try c.decodeIfPresent(Bool.self, forKey: .noAds) ?? true
        titles = try c.decodeIfPresent(ModePools.self, forKey: .titles) ?? ModePools()
        hooks = try c.decodeIfPresent(ModePools.self, forKey: .hooks) ?? ModePools()
        hear = try c.decodeIfPresent(ModePools.self, forKey: .hear) ?? ModePools()
        perfectFor = try c.decodeIfPresent(ModePools.self, forKey: .perfectFor) ?? ModePools()
        modeTags = try c.decodeIfPresent(ModePools.self, forKey: .modeTags) ?? ModePools()
        footer = try c.decodeIfPresent(String.self, forKey: .footer) ?? ""
        hashtags = try c.decodeIfPresent([String].self, forKey: .hashtags) ?? []
        coreTags = try c.decodeIfPresent([String].self, forKey: .coreTags) ?? []
        versions = try c.decodeIfPresent([Version].self, forKey: .versions) ?? []
        defaultPlaylist = try c.decodeIfPresent(String.self, forKey: .defaultPlaylist)
        music = try c.decodeIfPresent(String.self, forKey: .music) ?? ""
    }

    /// Whether `version`'s title and description carry the No-Ads label.
    public func showsNoAds(for version: Version) -> Bool { noAds && version.noAds }
}

/// The channel's look. Fonts and layouts are drawn by the thumbnail renderer (#72).
public struct ChannelBrand: Codable, Equatable, Sendable {
    public var layout: ThumbnailLayout
    /// Main text colour, "#RRGGBB".
    public var textColor: String
    /// Secondary colour (labels, bands, rules), "#RRGGBB".
    public var accentColor: String
    /// An installed font by name, e.g. "Avenir Next Condensed Bold". If it isn't
    /// installed, the system font is used.
    public var font: String

    public static let defaultFont = "Helvetica Neue Bold"

    public init(layout: ThumbnailLayout = .cornerNumber, textColor: String = "#FFFFFF",
                accentColor: String = "#FFFFFF", font: String = defaultFont) {
        self.layout = layout
        self.textColor = textColor
        self.accentColor = accentColor
        self.font = font
    }

    private enum CodingKeys: String, CodingKey { case layout, textColor, accentColor, font }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decodeIfPresent(ThumbnailLayout.self, forKey: .layout) ?? .cornerNumber
        textColor = try c.decodeIfPresent(String.self, forKey: .textColor) ?? "#FFFFFF"
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor) ?? textColor
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? Self.defaultFont
    }
}

/// The fixed thumbnail layouts a channel chooses from. Not a design tool: each is one
/// arrangement, styled only by the channel's colours, font and logo.
public enum ThumbnailLayout: String, Codable, CaseIterable, Sendable {
    /// Big hours number with the mode label in a corner.
    case cornerNumber
    /// A band across the middle with the scene name and duration.
    case centeredBand
    /// Just the logo and a small duration label.
    case minimalLogo
}

/// Text choices for one part of the kit: a shared pool plus optional per-mode pools.
/// In JSON, either a plain list (shared only) or `{"shared": [...], "byMode": {"Sleep": [...]}}`.
public struct ModePools: Codable, Equatable, Sendable {
    public var shared: [String]
    /// Keyed by mode; matched without regard to case.
    public var byMode: [String: [String]]

    public init(shared: [String] = [], byMode: [String: [String]] = [:]) {
        self.shared = shared
        self.byMode = byMode
    }

    /// The pool for `mode`: its own if it has one, otherwise the shared pool.
    public func pool(for mode: String) -> [String] {
        let key = mode.lowercased()
        if let own = byMode.first(where: { $0.key.lowercased() == key })?.value, !own.isEmpty { return own }
        return shared
    }

    /// Every entry with a label for error messages, e.g. ("byMode.Sleep[2]", "…").
    var labelledEntries: [(label: String, text: String)] {
        var entries = shared.enumerated().map { ("shared[\($0.offset)]", $0.element) }
        for mode in byMode.keys.sorted() {
            entries += byMode[mode, default: []].enumerated().map { ("byMode.\(mode)[\($0.offset)]", $0.element) }
        }
        return entries
    }

    private enum CodingKeys: String, CodingKey { case shared, byMode }

    public init(from decoder: any Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([String].self) {
            self.init(shared: list)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(shared: try c.decodeIfPresent([String].self, forKey: .shared) ?? [],
                  byMode: try c.decodeIfPresent([String: [String]].self, forKey: .byMode) ?? [:])
    }
}
