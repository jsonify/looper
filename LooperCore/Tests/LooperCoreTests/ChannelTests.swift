import Foundation
import Testing
@testable import LooperCore

/// The repo's starter channels (`channels/` at the repo root).
let starterChannelsFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("channels", isDirectory: true)

func validChannel() -> Channel {
    Channel(
        id: "test-channel", name: "Test Channel",
        brand: ChannelBrand(layout: .centeredBand, textColor: "#FFFFFF", accentColor: "#336699", font: "Georgia"),
        titles: ModePools(shared: ["{scene} | {duration}"], byMode: ["Sleep": ["{scene} for Sleep"]]),
        hooks: ModePools(shared: ["Relax."]),
        hear: ModePools(shared: ["You'll hear {elements}."]),
        perfectFor: ModePools(shared: ["Perfect for {mode}."]),
        modeTags: ModePools(byMode: ["Sleep": ["sleep sounds"]]),
        footer: "Subscribe to {channel}.",
        hashtags: ["#rain", "#sleep"], coreTags: ["rain sounds"],
        versions: [Version(name: "3h Sleep", duration: .threeHours), Version(name: "1h Study", duration: .oneHour)])
}

@Suite("Channel model")
struct ChannelModelTests {
    @Test func roundTripsThroughJSON() throws {
        let channel = validChannel()
        let decoded = try JSONDecoder().decode(Channel.self, from: try JSONEncoder().encode(channel))
        #expect(decoded == channel)
    }

    @Test func handWrittenShorthandDecodes() throws {
        let json = #"""
        {"id": "x", "name": "X", "titles": ["{scene}"], "hooks": ["Hi."], "perfectFor": ["Sleep well."],
         "versions": [{"name": "3h Sleep", "duration": "3h"}, {"duration": "1:30:00", "mode": "Focus"}]}
        """#
        let channel = try JSONDecoder().decode(Channel.self, from: Data(json.utf8))
        #expect(channel.titles == ModePools(shared: ["{scene}"]))
        #expect(channel.noAds)
        #expect(channel.brand == ChannelBrand())
        #expect(channel.versions.map(\.duration.seconds) == [10800, 5400])
        #expect(channel.versions.map(\.mode) == ["Sleep", "Focus"])
        #expect(channel.problems.isEmpty)
    }

    @Test func modePoolsFallBackToShared() {
        let pools = ModePools(shared: ["shared"], byMode: ["Sleep": ["sleep"], "Focus": []])
        #expect(pools.pool(for: "sleep") == ["sleep"])
        #expect(pools.pool(for: "Focus") == ["shared"])
        #expect(pools.pool(for: "Study") == ["shared"])
    }

    @Test func noAdsNeedsBothChannelAndVersion() {
        var channel = validChannel()
        let on = Version(duration: .oneHour)
        let off = Version(noAds: false, duration: .oneHour)
        #expect(channel.showsNoAds(for: on))
        #expect(!channel.showsNoAds(for: off))
        channel.noAds = false
        #expect(!channel.showsNoAds(for: on))
    }
}

@Suite("Channel validation")
struct ChannelValidationTests {
    @Test func validChannelHasNoProblems() throws {
        #expect(validChannel().problems == [])
        try validChannel().validate()
    }

    @Test func unknownPlaceholdersAndBadBracesAreCaught() {
        var channel = validChannel()
        channel.titles.byMode["Sleep"] = ["{senes} for Sleep", "{scene for Sleep", "scene} for Sleep"]
        channel.footer = "Watch {tracklist}"
        let fields = channel.problems.map(\.field)
        #expect(fields == ["titles.byMode.Sleep[0]", "titles.byMode.Sleep[1]", "titles.byMode.Sleep[2]", "footer"])
        #expect(channel.problems[0].message.contains("{senes}"))
    }

    @Test func everyDefaultModeNeedsItsPools() {
        var channel = validChannel()
        channel.hooks = ModePools(byMode: ["Sleep": ["Relax."]])
        #expect(channel.problems == [ChannelProblem("versions[1]", "mode “Study” has no hooks; add a shared or per-mode pool")])
    }

    @Test func brandAndTagMistakesAreCaught() {
        var channel = validChannel()
        channel.id = "Test Channel"
        channel.brand.textColor = "white"
        channel.coreTags = ["rain, sleep", "<b>"]
        channel.hashtags = ["rain", "#a b", "#c", "#d"]
        channel.versions.append(Version(name: "3H SLEEP", duration: .oneHour))
        let fields = Set(channel.problems.map(\.field))
        #expect(fields == ["id", "brand.textColor", "coreTags[0]", "coreTags[1]", "hashtags", "hashtags[0]",
                           "hashtags[1]", "versions[2]"])
    }

    @Test func aChannelNeedsVersions() {
        var channel = validChannel()
        channel.versions = []
        #expect(channel.problems.map(\.field) == ["versions"])
    }

    @Test(arguments: [
        ("{scene} | {duration}", [Placeholder.scene, .duration]),
        ("No placeholders", []),
        ("{music} over {elements}.", [.music, .elements]),
    ])
    func placeholdersAreRead(text: String, expected: [Placeholder]) throws {
        #expect(try TemplateText.placeholders(in: text) == expected)
    }
}

@Suite("Channel library")
struct ChannelLibraryTests {
    func write(_ text: String, to folder: URL, logo: Bool = false) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent(ChannelLibrary.fileName))
        if logo { try Data([0x89]).write(to: folder.appendingPathComponent(ChannelLibrary.logoFileName)) }
    }

    @Test func starterChannelsLoadAndAreValid() throws {
        let library = try ChannelLibrary.load(from: starterChannelsFolder)
        #expect(library.failures == [])
        #expect(library.channels.map(\.channel.name) == ["Hearth & Study", "Quiet Keys", "Rainfall Hours"])
        #expect(Set(library.channels.map(\.channel.brand.layout)) == Set(ThumbnailLayout.allCases))
        for loaded in library.channels {
            #expect(loaded.channel.noAds)
            #expect(loaded.channel.hashtags.count == 3)
            #expect(loaded.channel.versions.allSatisfy { !$0.mode.isEmpty })
        }
    }

    @Test func brokenChannelsDontHideTheOthers() throws {
        let root = try TemporaryFolder()
        defer { root.remove() }
        let good = try JSONEncoder().encode(validChannel())
        try write(String(decoding: good, as: UTF8.self), to: root.url.appendingPathComponent("a-good"), logo: true)
        try write(String(decoding: good, as: UTF8.self), to: root.url.appendingPathComponent("b-duplicate"))
        try write(#"{"id": "c", "name": "C", "titles": ["{nope}"], "hooks": ["x"], "perfectFor": ["y"], "versions": [{"duration": 60}]}"#,
                  to: root.url.appendingPathComponent("c-invalid"))
        try write(#"{"name": "No id"}"#, to: root.url.appendingPathComponent("d-undecodable"))
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("e-not-a-channel"), withIntermediateDirectories: true)

        let library = try ChannelLibrary.load(from: root.url)
        #expect(library.channels.map(\.channel.id) == ["test-channel"])
        #expect(library.channels.first?.logoURL?.lastPathComponent == "logo.png")
        #expect(library.channel(id: "test-channel")?.folder.lastPathComponent == "a-good")
        #expect(library.failures.map(\.folder.lastPathComponent) == ["b-duplicate", "c-invalid", "d-undecodable"])
        #expect(library.failures[0].message.contains("already uses the id"))
        #expect(library.failures[1].message.contains("{nope}"))
        #expect(library.failures[2].message.contains("missing “id”"))
    }

    @Test func defaultPlaylistResolvesAgainstTheChannelFolder() {
        var channel = validChannel()
        let folder = URL(fileURLWithPath: "/Channels/quiet-keys", isDirectory: true)
        func resolved(_ path: String?) -> String? {
            channel.defaultPlaylist = path
            return LoadedChannel(channel: channel, folder: folder).defaultPlaylistURL?.path
        }
        #expect(resolved(nil) == nil)
        #expect(resolved("../Music/Piano") == "/Channels/Music/Piano")
        #expect(resolved("/Volumes/Audio/Piano") == "/Volumes/Audio/Piano")
        #expect(resolved("~/Music/Piano") == (NSHomeDirectory() as NSString).appendingPathComponent("Music/Piano"))
    }
}

@Suite("Version mode and job scene")
struct VersionModeAndSceneTests {
    @Test(arguments: [("8h Sleep", "Sleep"), ("1h30m Deep Focus", "Deep Focus"), ("3h", ""), ("Sleep", "Sleep"),
                      ("1h0m10s", "")])
    func modeComesFromTheName(name: String, mode: String) {
        #expect(Version(name: name, duration: .oneHour).mode == mode)
    }

    @Test func olderFilesGetModeAndNoAdsDefaults() throws {
        let version = try JSONDecoder().decode(Version.self, from: Data(#"{"name": "3h Study", "duration": 10800}"#.utf8))
        #expect(version.mode == "Study")
        #expect(version.noAds)
        let job = try JSONDecoder().decode(Job.self, from: Data(#"{"clip": "file:///clips/cabin_rain_loop_30s_v2.mp4"}"#.utf8))
        #expect(job.channelID == nil)
        #expect(job.scene == SceneDetails(scene: "Cabin Rain"))
    }

    @Test(arguments: [
        ("cabin_rain_loop_30s_v2", "Cabin Rain"),
        ("rainy-log-cabin-4k-seamless", "Rainy Log Cabin"),
        ("Café at Night 1080p", "Café At Night"),
        ("loop_30s", "loop_30s"),
    ])
    func sceneNameFromFileName(file: String, scene: String) {
        #expect(SceneDetails.sceneName(fromFileName: file) == scene)
    }

    @Test func jobRoundTripsChannelAndScene() throws {
        let job = Job(clip: URL(fileURLWithPath: "/clips/a.mp4"), versions: [Version(duration: .oneHour)],
                      channelID: "quiet-keys",
                      scene: SceneDetails(scene: "Rainy Log Cabin", mood: "cozy", elements: ["rain", "fireplace"]))
        #expect(try JSONDecoder().decode(Job.self, from: try JSONEncoder().encode(job)) == job)
    }
}
