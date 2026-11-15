import Foundation
import Testing
@testable import LooperCore

private let clipURL = URL(fileURLWithPath: "/clips/cabin_rain_loop_30s_v2.mp4")

private func kitJob(_ versions: [Version], scene: SceneDetails = SceneDetails(scene: "Rainy Log Cabin", mood: "cozy",
                    elements: ["rain", "fireplace", "distant thunder"]), seed: UInt64 = 42) -> Job {
    Job(clip: clipURL, versions: versions, scene: scene, kitSeed: seed)
}

private func starter(_ id: String) throws -> Channel {
    try #require(try ChannelLibrary.load(from: starterChannelsFolder).channel(id: id)).channel
}

/// A channel with one pattern per pool, so the output is fully predictable.
private func plainChannel() -> Channel {
    Channel(
        id: "plain", name: "Plain Rain",
        titles: ModePools(shared: ["{mood} {scene} | {duration}"]),
        hooks: ModePools(shared: ["{duration} of rain."]),
        hear: ModePools(shared: ["you'll hear {elements}."]),
        perfectFor: ModePools(shared: ["Perfect for {mode}."]),
        modeTags: ModePools(byMode: ["Sleep": ["sleep sounds"]]),
        footer: "Subscribe to {channel}.", hashtags: ["#rain", "#sleep", "#ambience"],
        coreTags: ["rain sounds", "nature sounds"],
        versions: [Version(name: "3h Sleep", duration: .threeHours)])
}

@Suite("Placeholder values")
struct PlaceholderValuesTests {
    @Test func valuesComeFromTheJobVersionAndChannel() throws {
        var channel = plainChannel()
        channel.music = "soft piano"
        let job = kitJob([])
        let plain = PlaceholderValues(channel: channel, job: job, version: Version(name: "1h30m Sleep", duration: try TargetDuration(parsing: "1:30:00")))
        #expect(plain[.scene] == "Rainy Log Cabin")
        #expect(plain[.elements] == "rain, fireplace & distant thunder")
        #expect(plain[.hours] == "1.5")
        #expect(plain[.duration] == "1 Hour 30 Minutes")
        #expect(plain[.mode] == "Sleep")
        #expect(plain[.channel] == "Plain Rain")
        #expect(plain[.music] == "", "no playlist, no music")

        let withMusic = Version(duration: .threeHours,
                                audio: LoopAudioSettings(playlist: PlaylistSettings(folder: URL(fileURLWithPath: "/m"))))
        #expect(PlaceholderValues(channel: channel, job: job, version: withMusic)[.music] == "soft piano")
    }

    @Test(arguments: [(3600, "1 Hour"), (10800, "3 Hours"), (2700, "45 Minutes"), (3610, "1 Hour 10 Seconds")])
    func durationIsSpelledOut(seconds: Int, text: String) {
        #expect(PlaceholderValues.spelledOut(seconds) == text)
    }

    @Test(arguments: [(10800, "3"), (5400, "1.5"), (2700, "0.75")])
    func hoursAreShort(seconds: Int, text: String) {
        #expect(PlaceholderValues.hours(seconds) == text)
    }

    @Test func fillingSkipsEmptyPlaceholdersAndTitleCases() throws {
        let values = PlaceholderValues([.scene: "rainy cabin", .mood: ""])
        #expect(try values.fill("{scene} at night") == "rainy cabin at night")
        #expect(try values.fill("{scene} at night", titleCase: true) == "Rainy Cabin at night")
        #expect(try values.fill("{mood} {scene}") == nil)
        #expect(try values.fill("{mood}x", skippingEmpty: false) == "x")
        #expect(throws: TemplateText.ParseError.unknownPlaceholder("nope")) { try values.fill("{nope}") }
    }
}

@Suite("Publish kit text")
struct PublishKitTextTests {
    @Test func kitFollowsTheSpecLayout() throws {
        let version = Version(name: "3h Sleep", duration: .threeHours)
        let kit = try KitFactory(channel: plainChannel()).kit(for: version, in: kitJob([version]), history: ChannelHistory())
        #expect(kit.title == "Cozy Rainy Log Cabin | 3 Hours (No-Ads)")
        #expect(kit.description == """
            (No-Ads) 3 Hours of rain.

            You'll hear rain, fireplace & distant thunder.

            Perfect for Sleep.

            Subscribe to Plain Rain.

            #rain #sleep #ambience
            """)
        #expect(kit.tags == ["rainy log cabin", "rain", "fireplace", "distant thunder", "sleep sounds",
                             "3 hour sleep", "3 hours", "rain sounds", "nature sounds"])
        #expect(kit.tagsText.hasPrefix("rainy log cabin, rain, fireplace"))
        #expect(kit.notes == [KitFactory.noAdsNote])
    }

    @Test func noAdsCanBeTurnedOffPerVersionOrChannel() throws {
        let off = Version(name: "3h Sleep", noAds: false, duration: .threeHours)
        let kit = try KitFactory(channel: plainChannel()).kit(for: off, in: kitJob([off]), history: ChannelHistory())
        #expect(!kit.title.contains("No-Ads"))
        #expect(!kit.description.contains("No-Ads"))
        #expect(kit.notes.isEmpty)
    }

    @Test func patternsWithEmptyPlaceholdersAreSkipped() throws {
        var channel = plainChannel()
        channel.titles = ModePools(shared: ["{scene} for Sleep"], byMode: ["Sleep": ["{mood} {scene}"]])
        let version = Version(name: "3h Sleep", duration: .threeHours)
        let noMood = kitJob([version], scene: SceneDetails(scene: "Cabin"))
        let kit = try KitFactory(channel: channel).kit(for: version, in: noMood, history: ChannelHistory())
        #expect(kit.title == "Cabin for Sleep (No-Ads)", "falls back to the shared pool")
        #expect(!kit.description.contains("hear"), "no elements: the hear section is left out")

        let nothing = kitJob([version], scene: SceneDetails())
        #expect(throws: KitError.noUsableText(part: "title", version: "3h Sleep")) {
            try KitFactory(channel: channel).kit(for: version, in: nothing, history: ChannelHistory())
        }
    }

    @Test func titlesStayWithinOneHundredCharactersWithTheSuffix() throws {
        var channel = plainChannel()
        let long = String(repeating: "x", count: 92) // 92 + " (No-Ads)" = 101
        channel.titles = ModePools(shared: [long, String(repeating: "y", count: 91)])
        let version = Version(name: "3h Sleep", duration: .threeHours)
        for seed in 0..<20 as Range<UInt64> {
            let kit = try KitFactory(channel: channel).kit(for: version, in: kitJob([version], seed: seed), history: ChannelHistory())
            #expect(kit.title.count == 100)
            #expect(kit.title.hasPrefix("y"))
        }
    }

    @Test func overlongDescriptionIsAnError() {
        var channel = plainChannel()
        channel.footer = String(repeating: "a", count: 5000)
        let version = Version(name: "3h Sleep", duration: .threeHours)
        #expect(throws: KitError.self) {
            try KitFactory(channel: channel).kit(for: version, in: kitJob([version]), history: ChannelHistory())
        }
    }

    @Test func versionOverridesReplaceTitleAndHookAndAddTags() throws {
        let version = Version(name: "3h Sleep", duration: .threeHours,
                              publish: PublishTemplates(title: "Special: {scene}", description: "A one-off.", tags: ["Special"]))
        let kit = try KitFactory(channel: plainChannel()).kit(for: version, in: kitJob([version]), history: ChannelHistory())
        #expect(kit.title == "Special: Rainy Log Cabin (No-Ads)")
        #expect(kit.description.hasPrefix("(No-Ads) A one-off.\n\nYou'll hear"))
        #expect(kit.tags.prefix(5) == ["rainy log cabin", "rain", "fireplace", "distant thunder", "special"])

        let broken = Version(name: "3h Sleep", duration: .threeHours, publish: PublishTemplates(title: "{mood} only"))
        #expect(throws: KitError.unusableOverride(part: "title", version: "3h Sleep")) {
            try KitFactory(channel: plainChannel()).kit(for: broken, in: kitJob([broken], scene: SceneDetails(scene: "x")),
                                                        history: ChannelHistory())
        }
    }
}

@Suite("Publish kit tags")
struct PublishKitTagTests {
    @Test func tagsAreDeduplicatedInPriorityOrder() {
        #expect(KitFactory.tags([["Rain", "cabin"], ["rain ", "sleep"], [""], ["CABIN", "a,b"]])
                == ["rain", "cabin", "sleep", "ab"])
    }

    @Test func tagsStayUnderFiveHundredCharactersCountingQuotesAndCommas() {
        let specific = (0..<20).map { "scene tag \($0)" }           // 11–12 chars + 2 quotes each
        let core = (0..<40).map { "core\($0)" }
        let tags = KitFactory.tags([specific, core])
        let cost = tags.map { $0.count + ($0.contains(" ") ? 2 : 0) }.reduce(0, +) + tags.count - 1
        #expect(cost <= KitFactory.tagsLimit)
        #expect(Array(tags.prefix(20)) == specific, "the most specific tags survive")
        #expect(tags.count < 60)
    }

    @Test(arguments: [(10800, "Sleep", ["3 hour sleep", "3 hours"]), (3600, "Study", ["1 hour study", "1 hour"]),
                      (5400, "", ["90 minutes"])])
    func durationTags(seconds: Int, mode: String, expected: [String]) {
        #expect(KitFactory.durationTags(seconds: seconds, mode: mode) == expected)
    }
}

@Suite("Publish kit seeding and history")
struct PublishKitSeedingTests {
    @Test func sameSeedGivesTheSameKitAndShuffleChangesIt() throws {
        let channel = try starter("rainfall-hours")
        let version = Version(name: "3h Sleep", duration: .threeHours)
        var job = kitJob([version])
        let factory = KitFactory(channel: channel)
        let first = try factory.kit(for: version, in: job, history: ChannelHistory())
        #expect(try factory.kit(for: version, in: job, history: ChannelHistory()) == first)

        // Shuffling gives different text at least sometimes.
        var seen = Set([first.title + first.description])
        for _ in 0..<10 {
            job.shuffleKit()
            let kit = try factory.kit(for: version, in: job, history: ChannelHistory())
            seen.insert(kit.title + kit.description)
        }
        #expect(seen.count > 1)
    }

    @Test func jobSeedIsStableAcrossEncoding() throws {
        let job = Job(clip: clipURL)
        let decoded = try JSONDecoder().decode(Job.self, from: try JSONEncoder().encode(job))
        #expect(decoded.kitSeed == job.kitSeed)
        let legacy = try JSONDecoder().decode(Job.self, from: Data(#"{"id": "\#(job.id.uuidString)", "clip": "file:///a.mp4"}"#.utf8))
        #expect(legacy.kitSeed == job.kitSeed, "older files derive the seed from the job id")
    }

    @Test func recentUploadsPatternsAreAvoided() throws {
        let channel = try starter("rainfall-hours")
        let factory = KitFactory(channel: channel)
        var history = ChannelHistory()
        var titles: [String] = []
        var hooks: [String] = []
        // Fifteen uploads in a row, each on its own job.
        for upload in 0..<15 {
            let version = Version(name: "3h Sleep", duration: .threeHours)
            let kit = try factory.kit(for: version, in: kitJob([version], seed: UInt64(upload)), history: history)
            history.record(kit.historyEntry)
            titles.append(kit.titlePattern)
            hooks.append(kit.hook)
        }
        let titleWindow = min(ChannelHistory.recentWindow, channel.titles.shared.count - 1)
        for i in titles.indices {
            let recent = titles[max(0, i - titleWindow)..<i]
            #expect(!recent.contains(titles[i]), "title \(i) repeats one of the last \(titleWindow)")
        }
        for i in hooks.indices.dropFirst() { #expect(hooks[i] != hooks[i - 1]) }
    }

    @Test func smallPoolsRotateThroughTheLeastRecentlyUsed() {
        var random = KitRandom(seed: 1, "x")
        let used = ["a", "b", "c", "a", "b"]
        #expect(random.pick(["a", "b", "c"], avoiding: used) == "c")
        #expect(random.pick(["a", "b", "c"], avoiding: ["c", "a", "b", "c", "a"]) == "b")
    }

    @Test func versionsOfOneJobAvoidEachOther() throws {
        let channel = try starter("rainfall-hours")
        let job = kitJob([Version(name: "3h Sleep", duration: .threeHours), Version(name: "1h Sleep", duration: .oneHour)])
        let kits = try KitFactory(channel: channel).kits(for: job, history: ChannelHistory())
        #expect(kits[0].titlePattern != kits[1].titlePattern)
        #expect(kits[0].hook != kits[1].hook)
    }

    @Test func regeneratingIgnoresItsOwnAndLaterEntries() throws {
        let channel = try starter("rainfall-hours")
        let factory = KitFactory(channel: channel)
        let job = kitJob([Version(name: "3h Sleep", duration: .threeHours), Version(name: "1h Sleep", duration: .oneHour)])
        var history = ChannelHistory()
        let kits = try factory.kits(for: job, history: history)
        kits.forEach { history.record($0.historyEntry) }
        // A later upload on another job.
        let other = kitJob([Version(name: "3h Sleep", duration: .threeHours)], seed: 7)
        history.record(try factory.kit(for: other.versions[0], in: other, history: history).historyEntry)

        #expect(try factory.kits(for: job, history: history) == kits)
        history.record(kits[0].historyEntry)
        #expect(history.uploads.count == 3, "recording again replaces the entry")
    }

    @Test func historyRoundTripsAndKeepsTheNewest() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.file(ChannelHistory.fileName)
        #expect(try ChannelHistory.load(from: url) == ChannelHistory())
        var history = ChannelHistory()
        for i in 0..<(ChannelHistory.keptUploads + 5) {
            history.record(.init(key: "\(i)", date: Date(timeIntervalSince1970: 1_800_000_000), titlePattern: "t", hook: "h"))
        }
        #expect(history.uploads.count == ChannelHistory.keptUploads)
        #expect(history.uploads.first?.key == "5")
        try history.save(to: url)
        #expect(try ChannelHistory.load(from: url) == history)
    }
}

@Suite("Publish kit files")
struct PublishKitFileTests {
    @Test func starterChannelsMakeKitsForTheirDefaultVersions() throws {
        let library = try ChannelLibrary.load(from: starterChannelsFolder)
        for loaded in library.channels {
            let channel = loaded.channel
            let job = kitJob(channel.versions)
            let kits = try KitFactory(channel: channel).kits(for: job, history: ChannelHistory())
            for kit in kits {
                #expect(kit.title.hasSuffix(" (No-Ads)"))
                #expect(kit.title.count <= KitFactory.titleLimit)
                #expect(kit.description.hasPrefix("(No-Ads) "))
                #expect(kit.description.hasSuffix(channel.hashtags.joined(separator: " ")))
                #expect(!kit.title.contains("{") && !kit.description.contains("{"))
                #expect(kit.tags.first == "rainy log cabin")
            }
        }
    }

    @Test func quietKeysMentionsMusicOnlyWithAPlaylist() throws {
        let channel = try starter("quiet-keys")
        let plain = Version(name: "3h Sleep", duration: .threeHours)
        let piano = Version(name: "3h Sleep", duration: .threeHours,
                            audio: LoopAudioSettings(playlist: PlaylistSettings(folder: URL(fileURLWithPath: "/m"))))
        let factory = KitFactory(channel: channel)
        let without = try factory.kit(for: plain, in: kitJob([plain]), history: ChannelHistory())
        let with = try factory.kit(for: piano, in: kitJob([piano]), history: ChannelHistory())
        #expect(!without.description.lowercased().contains("soft piano over"))
        #expect(with.description.contains("Soft piano") || with.description.contains("soft piano with"))
    }

    @Test func regenerateWritesTheTextFilesAndHistory() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let historyURL = folder.file(ChannelHistory.fileName)
        let branding = Branding(channel: plainChannel(), historyURL: historyURL)
        let job = kitJob([Version(name: "3h Sleep", duration: .threeHours)])
        let output = folder.url.appendingPathComponent("out", isDirectory: true)

        let kits = try branding.regenerate(job, outputFolder: output)
        let versionFolder = job.videoURL(for: job.versions[0], in: output).deletingLastPathComponent()
        func read(_ name: String) throws -> String { try String(contentsOf: versionFolder.appendingPathComponent(name), encoding: .utf8) }
        #expect(try read(PublishKit.titleFileName) == kits[0].title)
        #expect(try read(PublishKit.descriptionFileName) == kits[0].description)
        #expect(try read(PublishKit.tagsFileName) == kits[0].tagsText)
        #expect(try ChannelHistory.load(from: historyURL).uploads.map(\.key) == [kits[0].historyKey])
    }
}

@Suite("Job runner with branding")
struct JobRunnerBrandingTests {
    @Test func finishedVersionsGetTheirKitAndHistory() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let historyURL = folder.file(ChannelHistory.fileName)
        let exporter = RecordingExporter(["1h Sleep": .fail])
        let runner = JobRunner(exporter: exporter, loadClip: { fakeClip(url: $0) })
        let job = kitJob([Version(name: "3h Sleep", duration: .threeHours), Version(name: "1h Sleep", duration: .oneHour)])
        let result = try await runner.run(job, outputFolder: folder.url,
                                          branding: Branding(channel: plainChannel(), historyURL: historyURL))

        let finished = try #require(result.finishedURLs.first)
        let kitFolder = finished.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: kitFolder.appendingPathComponent(PublishKit.titleFileName).path))
        let failedFolder = job.videoURL(for: job.versions[1], in: folder.url).deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: failedFolder.appendingPathComponent(PublishKit.titleFileName).path))
        #expect(try ChannelHistory.load(from: historyURL).uploads.count == 1, "only finished versions count as uploads")
    }

    @Test func aKitThatCantBeMadeStopsTheJobBeforeExporting() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let exporter = RecordingExporter()
        let runner = JobRunner(exporter: exporter, loadClip: { fakeClip(url: $0) })
        let job = kitJob([Version(name: "3h Sleep", duration: .threeHours)], scene: SceneDetails())
        await #expect(throws: KitError.self) {
            try await runner.run(job, outputFolder: folder.url, branding: Branding(channel: plainChannel(), historyURL: nil))
        }
        #expect(exporter.calls.isEmpty)
    }
}
