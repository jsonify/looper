import AVFoundation
import Observation

/// State and actions behind the Preview window: one `AVPlayer` playing a `LoopPreview`
/// of the current settings.
///
/// Changing what plays where (clip, length, bed or playlist files, crossfade lengths)
/// rebuilds the timeline and keeps the playhead where it was. Changing only levels and
/// fades swaps the audio mix on the playing item, so it's heard at once.
@MainActor
@Observable
public final class PreviewModel {
    public enum State: Equatable, Sendable {
        /// Nothing to preview yet; the text says why.
        case unavailable(String)
        case building
        case ready
        case failed(String)
    }

    /// Everything that changes the timeline's layout (not its levels). A preview is
    /// rebuilt only when this changes.
    public struct LayoutKey: Equatable, Sendable {
        let clip: URL?
        let plan: LoopPlan?
        let audio: LoopAudioSettings

        static let placeholderTrack = AudioTrackSettings(volume: 0, fadeIn: 0, fadeOut: 0)

        public init(clip: ClipInfo?, plan: LoopPlan?, audio: LoopAudioSettings) {
            self.clip = clip?.url
            self.plan = plan
            var layout = audio
            layout.bed?.track = Self.placeholderTrack
            layout.playlist?.track = Self.placeholderTrack
            layout.clipAudio.track = Self.placeholderTrack
            if clip?.hasAudio != true { layout.clipAudio.enabled = false }
            self.audio = layout
        }
    }

    public let player = AVPlayer()
    public private(set) var state: State = .unavailable("Choose a loop clip in the main window.")
    public private(set) var timeline: PreviewTimeline?
    public private(set) var currentTime: Double = 0
    public private(set) var isPlaying = false

    /// Preview only: these never change the export.
    public var muted: Set<AudioRole> = [] { didSet { applyMix() } }
    public var soloed: Set<AudioRole> = [] { didSet { applyMix() } }

    @ObservationIgnored private var preview: LoopPreview?
    @ObservationIgnored private var layout: LayoutKey?
    @ObservationIgnored private var audio = LoopAudioSettings()
    @ObservationIgnored private var buildToken = UUID()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var pendingSeeks = 0

    public init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                // While a seek is in flight the player can still report the old time
                // (or 0 just after a new item); the seek target set in `seek` stands.
                if time.isNumeric, self.pendingSeeks == 0 { self.currentTime = time.seconds }
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    // MARK: Inputs

    /// Brings the preview up to date with the main window's settings: rebuilds the
    /// timeline if its layout changed, otherwise just applies the new levels.
    public func update(clip: ClipInfo?, plan: LoopPlan?, audio: LoopAudioSettings) async {
        self.audio = audio
        let key = LayoutKey(clip: clip, plan: plan, audio: audio)
        guard key != layout else {
            applyMix()
            return
        }
        guard let clip, let plan else {
            reset(clip == nil ? "Choose a loop clip in the main window." : "Choose a valid length in the main window.")
            layout = key
            return
        }

        let token = UUID()
        buildToken = token
        state = .building
        do {
            let built = try await LoopPreview.build(clip: clip, plan: plan, audio: audio)
            guard buildToken == token else { return }
            install(built)
            layout = key
        } catch {
            guard buildToken == token else { return }
            reset(nil)
            state = .failed(error.localizedDescription)
            // Leave `layout` unset so the next update tries again.
            layout = nil
        }
    }

    /// Applies new levels and fades without rebuilding the timeline.
    public func setAudio(_ audio: LoopAudioSettings) {
        self.audio = audio
        applyMix()
    }

    // MARK: Playback

    public func play() {
        guard preview != nil else { return }
        // Play again from the start once the end is reached.
        if let timeline, currentTime >= timeline.duration - 0.05 { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlayback() { isPlaying ? pause() : play() }

    /// Seeks to the exact frame: the point is to see the frames around a seam.
    public func seek(to time: Double) {
        guard let timeline else { return }
        let t = min(max(time, 0), max(timeline.duration - timeline.frameDuration, 0))
        currentTime = t
        pendingSeeks += 1
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.pendingSeeks -= 1 }
        }
    }

    public func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    public func jump(_ jump: PreviewTimeline.Jump) {
        guard let target = jumpTime(jump) else { return }
        seek(to: target)
    }

    public func jumpTime(_ jump: PreviewTimeline.Jump) -> Double? {
        timeline?.time(for: jump, from: currentTime, finalFade: finalFadeLength)
    }

    /// The longest fade out among the audio in use; 10 s when there's none.
    public var finalFadeLength: Double {
        let fades = AudioRole.allCases.compactMap { role in
            timeline?.lane(role) != nil ? audio.track(for: role)?.fadeOut : nil
        }
        return fades.max().map { max($0, 1) } ?? 10
    }

    // MARK: Mix

    public func isAudible(_ role: AudioRole) -> Bool {
        !muted.contains(role) && (soloed.isEmpty || soloed.contains(role))
    }

    /// Level and fades `role` plays with in the preview (silent when muted).
    public func trackSettings(for role: AudioRole) -> AudioTrackSettings? {
        guard let track = audio.track(for: role) else { return nil }
        guard isAudible(role) else { return AudioTrackSettings(volume: 0, fadeIn: track.fadeIn, fadeOut: track.fadeOut) }
        return track
    }

    /// Each role's preview settings, for `LoopPreview.audioMix(for:)`.
    private var mixSettings: [AudioRole: AudioTrackSettings] {
        Dictionary(uniqueKeysWithValues: AudioRole.allCases.compactMap { role in trackSettings(for: role).map { (role, $0) } })
    }

    private func applyMix() {
        guard let preview, let item = player.currentItem else { return }
        // A new mix on the playing item takes effect straight away.
        item.audioMix = preview.audioMix(for: mixSettings)
    }

    private func install(_ built: LoopPreview) {
        let resume = currentTime
        preview = built
        timeline = built.timeline
        let item = AVPlayerItem(asset: built.composition)
        item.audioMix = built.audioMix(for: mixSettings)
        player.replaceCurrentItem(with: item)
        state = .ready
        seek(to: min(resume, built.timeline.duration))
    }

    private func reset(_ reason: String?) {
        buildToken = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        preview = nil
        timeline = nil
        currentTime = 0
        isPlaying = false
        if let reason { state = .unavailable(reason) }
    }
}
