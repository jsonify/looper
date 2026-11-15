import Foundation

/// The text half of a version's publish kit: what goes into YouTube's title, description
/// and tags fields, written next to the video as `title.txt`, `description.txt` and
/// `tags.txt`. (`thumbnail.jpg` comes with #72.)
public struct PublishKit: Equatable, Sendable {
    public var title: String
    public var description: String
    public var tags: [String]
    /// Reminders for the person uploading, e.g. turning ads off in YouTube Studio.
    /// Shown by the app and the CLI, not written to a file.
    public var notes: [String]
    /// The pattern and hook line chosen, recorded in the channel's history.
    public var titlePattern: String
    public var hook: String
    /// `ChannelHistory.key(job:version:)`.
    public var historyKey: String

    public static let titleFileName = "title.txt"
    public static let descriptionFileName = "description.txt"
    public static let tagsFileName = "tags.txt"

    /// Comma-separated, as YouTube's tags field takes them.
    public var tagsText: String { tags.joined(separator: ", ") }

    public var historyEntry: ChannelHistory.Upload {
        ChannelHistory.Upload(key: historyKey, titlePattern: titlePattern, hook: hook)
    }

    /// Writes the three text files into `folder`, replacing any already there.
    public func write(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in [(Self.titleFileName, title), (Self.descriptionFileName, description),
                             (Self.tagsFileName, tagsText)] {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }
}

public enum KitError: Error, Equatable, LocalizedError {
    /// No pattern in the pool (nor the shared pool) could be filled for this version:
    /// all use an empty placeholder or run over the length limit.
    case noUsableText(part: String, version: String)
    /// A per-version override can't be used as written.
    case unusableOverride(part: String, version: String)
    case badTemplate(part: String, TemplateText.ParseError)
    case descriptionTooLong(version: String, characters: Int)

    public var errorDescription: String? {
        switch self {
        case .noUsableText(let part, let version):
            "No \(part) line can be made for “\(version)”: each one uses a placeholder this job leaves empty "
                + "(fill in the scene, mood or elements) or is too long."
        case .unusableOverride(let part, let version):
            "The \(part) override for “\(version)” uses a placeholder this job leaves empty or is too long."
        case .badTemplate(let part, let error):
            "A \(part) template \(error.description)."
        case .descriptionTooLong(let version, let characters):
            "The description for “\(version)” would be \(characters) characters; YouTube allows "
                + "\(KitFactory.descriptionLimit). Shorten the channel's footer."
        }
    }
}

/// Makes publish kits from a channel's templates (spec: "Channels and branding factory").
///
/// Choices are seeded by the job's `kitSeed` and each version's id, so making a kit again
/// gives the same text until the job is shuffled. The channel's history steers each
/// choice away from what recent uploads used.
public struct KitFactory: Sendable {
    public static let titleLimit = 100
    public static let descriptionLimit = 5000
    public static let tagsLimit = 500
    public static let noAdsLabel = "(No-Ads)"
    public static let noAdsNote = "Turn ads off for this video in YouTube Studio: its title and description say “(No-Ads)”."

    public var channel: Channel

    public init(channel: Channel) {
        self.channel = channel
    }

    /// Kits for every version of `job`, in order. Each version also avoids the choices of
    /// the versions before it, since they're uploaded close together.
    public func kits(for job: Job, history: ChannelHistory) throws(KitError) -> [PublishKit] {
        var history = history
        var kits: [PublishKit] = []
        for version in job.versions {
            let kit = try kit(for: version, in: job, history: history)
            history.record(kit.historyEntry)
            kits.append(kit)
        }
        return kits
    }

    public func kit(for version: Version, in job: Job, history: ChannelHistory) throws(KitError) -> PublishKit {
        let values = PlaceholderValues(channel: channel, job: job, version: version)
        let key = ChannelHistory.key(job: job, version: version)
        let earlier = history.uploads(before: key)
        let noAds = channel.showsNoAds(for: version)
        let override = version.publish
        func random(_ part: String) -> KitRandom { KitRandom(seed: job.kitSeed, part, version.id.uuidString) }

        // Title: pattern + " (No-Ads)", 100 characters in all.
        let suffix = noAds ? " " + Self.noAdsLabel : ""
        var titleRandom = random("title")
        let title = try choose(
            "title", pools: channel.titles, override: override.title, version: version, values: values,
            titleCase: true, avoiding: earlier.map(\.titlePattern), random: &titleRandom,
            accept: { $0.count + suffix.count <= Self.titleLimit })

        // Description sections.
        var hookRandom = random("hook")
        let hook = try choose(
            "hook", pools: channel.hooks, override: override.description, version: version, values: values,
            avoiding: earlier.map(\.hook), random: &hookRandom)
        var hearRandom = random("hear")
        // Optional section: left out when nothing in the pool can be filled.
        let hear: (pattern: String, text: String)?
        do { hear = try choose("hear", pools: channel.hear, version: version, values: values, random: &hearRandom) } catch {
            guard case .noUsableText = error else { throw error }
            hear = nil
        }
        var perfectRandom = random("perfectFor")
        let perfectFor = try choose("Perfect for", pools: channel.perfectFor, version: version, values: values,
                                    random: &perfectRandom)
        let footer: String
        do { footer = try values.fill(channel.footer, skippingEmpty: false) ?? "" } catch {
            throw .badTemplate(part: "footer", error)
        }
        let sections = [
            (noAds ? Self.noAdsLabel + " " : "") + PlaceholderValues.capitalisingFirst(hook.text),
            hear.map { PlaceholderValues.capitalisingFirst($0.text) } ?? "",
            PlaceholderValues.capitalisingFirst(perfectFor.text),
            footer.trimmed,
            channel.hashtags.prefix(3).joined(separator: " "),
        ]
        let description = sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard description.count <= Self.descriptionLimit else {
            throw .descriptionTooLong(version: version.name, characters: description.count)
        }

        // Tags, most specific first.
        let sceneTags = [values[.scene]] + job.scene.elements + override.tags
        let tags = Self.tags([sceneTags, channel.modeTags.pool(for: version.mode),
                              Self.durationTags(seconds: version.duration.seconds, mode: version.mode),
                              channel.coreTags])

        return PublishKit(title: title.text + suffix, description: description, tags: tags,
                          notes: noAds ? [Self.noAdsNote] : [], titlePattern: title.pattern, hook: hook.pattern,
                          historyKey: key)
    }

    /// Picks a pattern that can be filled for this version: from the override if there is
    /// one, else the mode's pool, else the shared pool.
    private func choose(
        _ part: String, pools: ModePools, override: String = "", version: Version, values: PlaceholderValues,
        titleCase: Bool = false, avoiding used: [String] = [], random: inout KitRandom,
        accept: (String) -> Bool = { _ in true }
    ) throws(KitError) -> (pattern: String, text: String) {
        func usable(_ pool: [String]) throws(KitError) -> [(pattern: String, text: String)] {
            var found: [(pattern: String, text: String)] = []
            for pattern in pool {
                let filled: String?
                do { filled = try values.fill(pattern, titleCase: titleCase) } catch {
                    throw .badTemplate(part: part, error)
                }
                if let text = filled?.trimmed, !text.isEmpty, accept(text) { found.append((pattern, text)) }
            }
            return found
        }

        if !override.trimmed.isEmpty {
            guard let only = try usable([override]).first else {
                throw .unusableOverride(part: part, version: version.name)
            }
            return only
        }
        for pool in [pools.pool(for: version.mode), pools.shared] {
            let candidates = try usable(pool)
            if let pattern = random.pick(candidates.map(\.pattern), avoiding: used),
               let chosen = candidates.first(where: { $0.pattern == pattern }) {
                return chosen
            }
        }
        throw .noUsableText(part: part, version: version.name)
    }

    /// "3 hour sleep", "3 hours" (or "90 minute …" when not whole hours).
    static func durationTags(seconds: Int, mode: String) -> [String] {
        let (count, unit) = seconds % 3600 == 0 ? (seconds / 3600, "hour") : (Int((Double(seconds) / 60).rounded()), "minute")
        let mode = mode.trimmed.lowercased()
        return (mode.isEmpty ? [] : ["\(count) \(unit) \(mode)"]) + ["\(count) \(unit)\(count == 1 ? "" : "s")"]
    }

    /// Flattens tag groups in priority order: trimmed, lower-cased, duplicates dropped,
    /// and kept under YouTube's 500-character total. YouTube counts the commas between
    /// tags and the quotes it adds around tags with spaces, so this does too. A tag that
    /// doesn't fit is skipped; shorter, lower-priority ones may still fit after it.
    static func tags(_ groups: [[String]]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        var used = 0
        for raw in groups.joined() {
            let tag = raw.trimmed.lowercased().filter { !",<>".contains($0) }
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            let cost = tag.count + (tag.contains(" ") ? 2 : 0) + (kept.isEmpty ? 0 : 1)
            guard used + cost <= tagsLimit else { continue }
            kept.append(tag)
            used += cost
        }
        return kept
    }
}

/// A channel plus where its history lives: what `JobRunner` needs to write kits at export.
public struct Branding: Sendable {
    public var channel: Channel
    /// nil keeps no history (choices still vary by seed).
    public var historyURL: URL?

    public init(channel: Channel, historyURL: URL?) {
        self.channel = channel
        self.historyURL = historyURL
    }

    public init(_ loaded: LoadedChannel) {
        self.init(channel: loaded.channel, historyURL: loaded.historyURL)
    }

    public func loadHistory() throws -> ChannelHistory {
        try historyURL.map(ChannelHistory.load(from:)) ?? ChannelHistory()
    }

    /// Makes every version's kit and checks each can be made, without writing anything.
    public func kits(for job: Job) throws -> [PublishKit] {
        try KitFactory(channel: channel).kits(for: job, history: loadHistory())
    }

    /// Rewrites the text files of every version of `job` without re-exporting the videos
    /// ("Regenerate kit"), and records the choices in the channel's history.
    @discardableResult
    public func regenerate(_ job: Job, outputFolder: URL) throws -> [PublishKit] {
        var history = try loadHistory()
        let kits = try KitFactory(channel: channel).kits(for: job, history: history)
        for (version, kit) in zip(job.versions, kits) {
            try kit.write(to: job.videoURL(for: version, in: outputFolder).deletingLastPathComponent())
            history.record(kit.historyEntry)
        }
        try historyURL.map(history.save(to:))
        return kits
    }

    /// Records one finished version's choices.
    func record(_ kit: PublishKit) throws {
        guard let historyURL else { return }
        var history = try ChannelHistory.load(from: historyURL)
        history.record(kit.historyEntry)
        try history.save(to: historyURL)
    }
}
