import Foundation
import Observation

/// Something that can write a loop to a file. `LoopWriter` in the app; tests inject fakes.
public protocol LoopExporting: Sendable {
    func export(
        clip: ClipInfo,
        plan: LoopPlan,
        audio: LoopAudioSettings?,
        to outputURL: URL,
        overwrite: Bool,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws
}

extension LoopWriter: LoopExporting {
    public func export(
        clip: ClipInfo, plan: LoopPlan, audio: LoopAudioSettings?, to outputURL: URL, overwrite: Bool,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        try await export(clip: clip, plan: plan, audio: audio, fileType: .mp4, to: outputURL,
                         overwrite: overwrite, progress: progress)
    }
}

/// State and actions behind the main window: the clip, the duration, the output folder
/// and the export. The SwiftUI views only display it and call its methods, so all the
/// rules (what blocks an export, where the file goes, what happens on cancel) are
/// tested here without UI.
///
/// Uses the Observation framework, not SwiftUI, so it can live in LooperCore.
@MainActor
@Observable
public final class LooperModel {
    public enum DurationChoice: Hashable, Sendable {
        case preset(TargetDuration)
        case custom
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case exporting
        case finished(URL)
        case failed(String)
        case cancelled
    }

    // MARK: Inputs

    public private(set) var clip: ClipInfo?
    public private(set) var poster: PosterImage?
    public private(set) var clipError: String?
    public private(set) var isLoadingClip = false

    public var durationChoice: DurationChoice = .preset(.eightHours)
    /// Text of the custom duration field (h:mm:ss, m:ss, 8h, 45m).
    public var customDuration = "1:00:00"

    /// Remembered between launches.
    public var outputFolder: URL? {
        didSet { defaults.set(outputFolder?.path, forKey: Self.outputFolderKey) }
    }

    // MARK: Audio

    /// Bed, playlist and clip audio settings for the next export.
    public var audio = LoopAudioSettings()
    public private(set) var bedItem: AudioItem?
    public private(set) var playlistItems: [AudioItem] = []
    public private(set) var audioError: String?

    // MARK: Export state

    public private(set) var phase: Phase = .idle
    public private(set) var progress: ExportProgress?
    public private(set) var exportStartedAt: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let exporter: any LoopExporting
    @ObservationIgnored private let availableSpace: @Sendable (URL) -> Int64?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var loadToken = UUID()

    static let outputFolderKey = "outputFolder"

    public init(
        defaults: UserDefaults = .standard,
        exporter: any LoopExporting = LoopWriter(),
        availableSpace: @escaping @Sendable (URL) -> Int64? = DiskSpace.availableBytes
    ) {
        self.defaults = defaults
        self.exporter = exporter
        self.availableSpace = availableSpace
        if let path = defaults.string(forKey: Self.outputFolderKey) {
            outputFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        }
    }

    // MARK: Derived values

    public var target: TargetDuration? { try? targetResult.get() }

    /// Why the custom duration isn't valid, if it isn't.
    public var targetError: String? {
        if case .failure(let error) = targetResult { return error.localizedDescription }
        return nil
    }

    private var targetResult: Result<TargetDuration, any Error> {
        switch durationChoice {
        case .preset(let target): .success(target)
        case .custom: Result { try TargetDuration(parsing: customDuration) }
        }
    }

    public var plan: LoopPlan? {
        guard let clip, let target else { return nil }
        return LoopPlan(clip: clip, target: target)
    }

    /// e.g. "960 copies · 864,000 frames" or "120 copies + 0:00:10 · 108,300 frames".
    public var planSummary: String? {
        guard let plan else { return nil }
        var copies = "\(plan.fullCopies) \(plan.fullCopies == 1 ? "copy" : "copies")"
        if plan.remainderFrames > 0 { copies += " + \(Self.clock(plan.remainder.seconds))" }
        return "\(copies) · \(plan.frameCount.formatted()) frames"
    }

    /// Where the video will be written (before any "video 2.mp4" renaming).
    public var outputURL: URL? {
        guard let clip, let target, let outputFolder else { return nil }
        return OutputLayout.videoURL(in: outputFolder, clip: clip.url,
                                     versionName: OutputLayout.versionName(for: target))
    }

    public var outputExists: Bool {
        outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public var estimatedBytes: Int64? {
        guard let clip, let plan else { return nil }
        var bytes = OutputEstimate.bytes(clip: clip, plan: plan)
        if audio.hasAudio(clipHasAudio: clip.hasAudio) {
            bytes += Int64(Double(LoopAudioSettings.bitRate) / 8 * plan.duration.seconds)
        }
        return bytes
    }

    /// Audio that will actually be used (nil when the output will be silent).
    var exportAudio: LoopAudioSettings? {
        audio.hasAudio(clipHasAudio: clip?.hasAudio ?? false) ? audio : nil
    }

    /// e.g. "5 songs · 0:24:10 · plays 20× in 8 h".
    public var playlistSummary: String? {
        guard !playlistItems.isEmpty else { return nil }
        let length = playlistItems.reduce(0) { $0 + $1.seconds }
        var text = "\(playlistItems.count) \(playlistItems.count == 1 ? "song" : "songs") · \(Self.clock(length))"
        if let target, length > 0 {
            let plays = Double(target.seconds) / length
            if plays > 1 { text += " · plays \(plays.formatted(.number.precision(.fractionLength(0...1))))× in \(target)" }
        }
        return text
    }

    /// Things worth knowing about the chosen audio, shown under the audio section.
    public var audioNotes: [String] {
        var notes: [String] = []
        if let bed = bedItem {
            if bed.seconds < 60 {
                notes.append("The bed is \(Int(bed.seconds)) s long, so its repetition may be audible. Beds of 5–10 minutes work best.")
            }
            if !bed.isLossless { notes.append("The bed is already compressed (\(bed.codec.trimmingCharacters(in: .whitespaces))); a lossless file (WAV, AIFF, FLAC) avoids encoding it twice.") }
        }
        let lossy = playlistItems.filter { !$0.isLossless }
        if !lossy.isEmpty {
            notes.append("\(lossy.count) of the songs are already compressed; lossless files (WAV, AIFF, FLAC) avoid encoding them twice.")
        }
        return notes
    }

    public var spaceCheck: SpaceCheck? {
        guard let estimatedBytes, let outputURL else { return nil }
        return SpaceCheck.evaluate(estimatedBytes: estimatedBytes, availableBytes: availableSpace(outputURL))
    }

    /// Why Export is disabled, or nil when it isn't.
    public var exportBlockedReason: String? {
        if isExporting { return "An export is running." }
        if isLoadingClip { return "Loading the clip…" }
        if clip == nil { return "Choose a loop clip." }
        if let targetError { return targetError }
        if outputFolder == nil { return "Choose an output folder." }
        if let check = spaceCheck, check.level == .insufficient { return check.message }
        return nil
    }

    public var canExport: Bool { exportBlockedReason == nil }
    public var isExporting: Bool { phase == .exporting }

    public var exportElapsed: TimeInterval? {
        guard isExporting, let exportStartedAt else { return nil }
        return Date().timeIntervalSince(exportStartedAt)
    }

    // MARK: Actions

    /// Opens and checks a clip. A later call wins if two loads overlap.
    public func loadClip(from url: URL) async {
        guard !isExporting else { return }
        let token = UUID()
        loadToken = token
        isLoadingClip = true
        clipError = nil
        defer { if loadToken == token { isLoadingClip = false } }
        do {
            let info = try await ClipInfo.load(from: url)
            guard loadToken == token else { return }
            clip = info
            poster = nil
            phase = .idle
            progress = nil
            let image = try? await PosterImage.firstFrame(of: url)
            if loadToken == token { poster = image }
        } catch {
            guard loadToken == token else { return }
            clip = nil
            poster = nil
            clipError = error.localizedDescription
        }
    }

    /// Starts the export. If the output file already exists, `replacing` chooses
    /// between overwriting it and writing "video 2.mp4" next to it.
    public func startExport(replacing: Bool = false) {
        guard canExport, let clip, let plan, let destination = outputURL else { return }
        let url = replacing ? destination : OutputLayout.nextAvailable(destination)
        phase = .exporting
        progress = ExportProgress(fractionCompleted: 0, estimatedTimeRemaining: nil)
        exportStartedAt = Date()
        // Long exports are often left running: keep the Mac from idle-sleeping.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Exporting a long video")

        let exporter = self.exporter
        let audio = exportAudio
        exportTask = Task {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await exporter.export(clip: clip, plan: plan, audio: audio, to: url, overwrite: replacing) { [weak self] update in
                    Task { @MainActor in self?.receive(update) }
                }
                finish(.finished(url))
            } catch is CancellationError {
                finish(.cancelled)
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    public func cancelExport() {
        exportTask?.cancel()
    }

    /// Uses `url` as the ambient bed, keeping the current level and fades.
    public func chooseBed(_ url: URL) async {
        do {
            let item = try await AudioItem.load(from: url)
            bedItem = item
            audio.bed = BedSettings(file: url, track: audio.bed?.track ?? BedSettings.defaultTrack,
                                    wrapCrossfade: audio.bed?.wrapCrossfade ?? BedSettings.defaultWrapCrossfade)
            audioError = nil
        } catch {
            audioError = error.localizedDescription
        }
    }

    public func removeBed() {
        audio.bed = nil
        bedItem = nil
    }

    /// Uses the audio files in `folder` as the playlist, keeping the current level and fades.
    public func choosePlaylist(_ folder: URL) async {
        do {
            let items = try await FolderAudioSource(folder: folder).items()
            playlistItems = items
            audio.playlist = PlaylistSettings(folder: folder, track: audio.playlist?.track ?? PlaylistSettings.defaultTrack,
                                              crossfade: audio.playlist?.crossfade ?? PlaylistSettings.defaultCrossfade)
            audioError = nil
        } catch {
            audioError = error.localizedDescription
        }
    }

    public func removePlaylist() {
        audio.playlist = nil
        playlistItems = []
    }

    /// Clears a finished, failed or cancelled result.
    public func dismissResult() {
        guard !isExporting else { return }
        phase = .idle
        progress = nil
    }

    private func receive(_ update: ExportProgress) {
        guard isExporting else { return }
        // Progress hops to the main actor in separate tasks; drop any that arrive late.
        if let current = progress, update.fractionCompleted < current.fractionCompleted { return }
        progress = update
    }

    private func finish(_ result: Phase) {
        phase = result
        if case .finished = result {
            progress = ExportProgress(fractionCompleted: 1, estimatedTimeRemaining: 0)
        }
        exportTask = nil
        exportStartedAt = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// "0:00:10", "1:30:00".
    nonisolated static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
