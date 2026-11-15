import AVKit
import LooperCore
import SwiftUI

/// The Preview window: plays the layered output (looped clip plus bed, playlist and clip
/// audio, with every fade and crossfade) live, before exporting. Settings changed here
/// are the main window's settings, so the export uses them; mute and solo are preview only.
struct PreviewView: View {
    @Environment(LooperModel.self) private var model
    @Environment(PreviewModel.self) private var preview

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    PlayerArea()
                    TransportBar()
                    JumpBar()
                }
                .padding(14)
                Divider()
                TimelineArea()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .frame(minWidth: 560, maxWidth: .infinity)
            MixInspector()
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 340)
        }
        .frame(minWidth: 820, minHeight: 560)
        // Rebuild the timeline when its layout changes (debounced, so typing a crossfade
        // length doesn't rebuild on every keystroke)...
        .task(id: PreviewModel.LayoutKey(clip: model.clip, plan: model.plan, audio: model.audio)) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await preview.update(clip: model.clip, plan: model.plan, audio: model.audio)
        }
        // ...and apply level and fade changes straight away.
        .onChange(of: model.audio) { _, audio in preview.setAudio(audio) }
        // An export needs the machine; don't play over it.
        .onChange(of: model.isExporting) { _, exporting in if exporting { preview.pause() } }
        .onDisappear { preview.pause() }
    }
}

/// Colours of the timeline lanes and inspector swatches.
enum LaneStyle {
    static let video = Color(red: 0.36, green: 0.50, blue: 0.66)

    static func color(_ role: AudioRole) -> Color {
        switch role {
        case .bed: Color(red: 0.25, green: 0.61, blue: 0.54)
        case .playlist: Color(red: 0.54, green: 0.44, blue: 0.82)
        case .clipAudio: Color(red: 0.79, green: 0.54, blue: 0.23)
        }
    }

    static func name(_ role: AudioRole) -> String {
        switch role {
        case .bed: "Ambient bed"
        case .playlist: "Music playlist"
        case .clipAudio: "Clip audio"
        }
    }

    static func shortName(_ role: AudioRole) -> String {
        switch role {
        case .bed: "Bed"
        case .playlist: "Music"
        case .clipAudio: "Clip audio"
        }
    }
}

// MARK: - Player

private struct PlayerArea: View {
    @Environment(PreviewModel.self) private var preview

    var body: some View {
        ZStack {
            Color.black
            switch preview.state {
            case .unavailable(let reason):
                message(reason, systemImage: "film")
            case .failed(let error):
                message("Couldn't build the preview: \(error)", systemImage: "exclamationmark.triangle")
            case .building, .ready:
                PlayerView(player: preview.player)
                if preview.state == .building {
                    ProgressView("Building preview…").controlSize(.small).padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomLeading) {
            if let timeline = preview.timeline {
                let position = timeline.position(at: preview.currentTime)
                Text("copy \(position.copy) of \(timeline.copyCount) · frame \(position.frame)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .padding()
    }
}

/// AVKit's player view without its own controls: the window has its own transport,
/// jump buttons and timeline.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - Transport and jumps

private struct TransportBar: View {
    @Environment(PreviewModel.self) private var preview

    var body: some View {
        HStack(spacing: 8) {
            Button("Back 10 Seconds", systemImage: "gobackward.10") { preview.skip(by: -10) }
            Button(preview.isPlaying ? "Pause" : "Play", systemImage: preview.isPlaying ? "pause.fill" : "play.fill") {
                preview.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .frame(minWidth: 80)
            Button("Forward 10 Seconds", systemImage: "goforward.10") { preview.skip(by: 10) }
            Text(time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 160)
        }
        .labelStyle(.iconOnly)
        .disabled(preview.timeline == nil)
    }

    private var time: String {
        guard let timeline = preview.timeline else { return "–:––:–– / –:––:––" }
        return "\(PreviewFormat.clock(preview.currentTime, fraction: true)) / \(Format.clock(timeline.duration))"
    }
}

private struct JumpBar: View {
    @Environment(PreviewModel.self) private var preview

    var body: some View {
        HStack(spacing: 6) {
            Text("Jump to").foregroundStyle(.secondary)
            button("Start", .start)
            button("Next Seam", .nextSeam)
                .help("Lands 3 s before the next point where the clip starts over.")
            if preview.timeline?.lane(.bed) != nil {
                button("Next Bed Wrap", .nextBedWrap)
                    .help("Lands 3 s before the bed next loops back to its start.")
            }
            if preview.timeline?.lane(.playlist) != nil {
                button("Next Song", .nextSongChange)
                    .help("Lands 3 s before the next song starts.")
            }
            button("Final Fade", .finalFade)
                .help("The last part of the video, where the fades out play.")
        }
        .controlSize(.small)
    }

    private func button(_ title: String, _ jump: PreviewTimeline.Jump) -> some View {
        Button(title) { preview.jump(jump) }
            .disabled(preview.jumpTime(jump) == nil)
    }
}

// MARK: - Timeline

private struct TimelineArea: View {
    @Environment(LooperModel.self) private var model
    @Environment(PreviewModel.self) private var preview
    @State private var zoom = Zoom.twoMinutes
    /// Start of the visible stretch. It pages along when the playhead leaves it, rather
    /// than scrolling under the pointer while you click or drag to seek.
    @State private var windowStart = 0.0

    enum Zoom: Double, CaseIterable, Identifiable {
        case twoMinutes = 120, thirtyMinutes = 1800, whole = 0
        var id: Double { rawValue }
        var title: String {
            switch self {
            case .twoMinutes: "2 min"
            case .thirtyMinutes: "30 min"
            case .whole: "Whole Video"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(spanDescription).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Zoom", selection: $zoom) {
                    ForEach(Zoom.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let timeline = preview.timeline {
                TimelineLanes(timeline: timeline, window: window(timeline), current: preview.currentTime,
                              level: { role, t in
                                  preview.trackSettings(for: role).map { timeline.level(role, at: t, settings: $0) } ?? 0
                              },
                              seek: { preview.seek(to: $0) })
            } else {
                Text("The timeline appears once there's something to preview.")
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .onChange(of: preview.currentTime) { _, _ in follow(force: false) }
        .onChange(of: zoom) { _, _ in follow(force: true) }
    }

    private func span(_ timeline: PreviewTimeline) -> Double {
        zoom == .whole ? timeline.duration : min(zoom.rawValue, timeline.duration)
    }

    private func window(_ timeline: PreviewTimeline) -> ClosedRange<Double> {
        let span = span(timeline)
        let start = min(max(windowStart, 0), max(timeline.duration - span, 0))
        return start...(start + span)
    }

    /// Pages the visible stretch so the playhead stays in view, a quarter of the way in.
    private func follow(force: Bool) {
        guard let timeline = preview.timeline else { return }
        let visible = window(timeline)
        let t = preview.currentTime
        if force || !visible.contains(t) {
            windowStart = t - span(timeline) / 4
        }
    }

    private var spanDescription: String {
        guard let timeline = preview.timeline else { return " " }
        if zoom == .whole { return "Whole video: \(Format.clock(timeline.duration))" }
        let w = window(timeline)
        return "\(Format.clock(w.lowerBound)) – \(Format.clock(w.upperBound))"
    }
}

/// The lanes: video copies with their seams, then each audio part's pieces with
/// crossfades and a level line, and a playhead. Click or drag to seek.
private struct TimelineLanes: View {
    let timeline: PreviewTimeline
    let window: ClosedRange<Double>
    let current: Double
    let level: (AudioRole, Double) -> Float
    let seek: (Double) -> Void

    static let laneHeight: CGFloat = 22
    static let gap: CGFloat = 5
    static let rulerHeight: CGFloat = 16
    static let nameWidth: CGFloat = 80

    private var rows: [(name: String, color: Color, role: AudioRole?)] {
        [("Video", LaneStyle.video, nil)] + timeline.lanes.map { (LaneStyle.shortName($0.role), LaneStyle.color($0.role), $0.role) }
    }

    var body: some View {
        let height = Self.rulerHeight + CGFloat(rows.count) * (Self.laneHeight + Self.gap)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: Self.gap) {
                Color.clear.frame(height: Self.rulerHeight - Self.gap)
                ForEach(rows.indices, id: \.self) { i in
                    Label {
                        Text(rows[i].name)
                    } icon: {
                        RoundedRectangle(cornerRadius: 2).fill(rows[i].color).frame(width: 9, height: 9)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: Self.laneHeight)
                }
            }
            .frame(width: Self.nameWidth, alignment: .leading)

            GeometryReader { geometry in
                Canvas { context, size in draw(in: &context, size: size) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let fraction = min(max(value.location.x / geometry.size.width, 0), 1)
                        seek(window.lowerBound + fraction * span)
                    })
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue(Format.clock(current))
    }

    private var span: Double { max(window.upperBound - window.lowerBound, 0.001) }

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat { CGFloat((t - window.lowerBound) / span) * width }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        drawRuler(in: &context, width: size.width)
        for (index, row) in rows.enumerated() {
            let top = Self.rulerHeight + CGFloat(index) * (Self.laneHeight + Self.gap)
            let lane = CGRect(x: 0, y: top, width: size.width, height: Self.laneHeight)
            context.fill(Path(roundedRect: lane, cornerRadius: 4), with: .color(.secondary.opacity(0.15)))
            if let role = row.role, let audio = timeline.lane(role) {
                drawPieces(audio, color: row.color, in: lane, context: &context)
                drawLevel(role, in: lane, context: &context)
            } else {
                drawVideo(in: lane, context: &context)
            }
        }
        // Playhead
        let px = x(current, size.width)
        if px >= 0, px <= size.width {
            var line = Path()
            line.move(to: CGPoint(x: px, y: Self.rulerHeight - 4))
            line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .color(.red), lineWidth: 2)
        }
    }

    private func drawRuler(in context: inout GraphicsContext, width: CGFloat) {
        // A tick step that gives at most about 8 labels.
        let steps: [Double] = [10, 30, 60, 300, 600, 1800, 3600, 7200]
        let step = steps.first { span / $0 <= 8 } ?? 7200
        var t = (window.lowerBound / step).rounded(.up) * step
        while t <= window.upperBound {
            let label = Text(Format.clock(t)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            context.draw(label, at: CGPoint(x: min(max(x(t, width), 24), width - 24), y: 6))
            t += step
        }
    }

    private func drawVideo(in lane: CGRect, context: inout GraphicsContext) {
        context.fill(Path(roundedRect: lane.insetBy(dx: 0, dy: 2), cornerRadius: 3), with: .color(LaneStyle.video))
        // Seam lines only when they're far enough apart to see.
        if span / timeline.clipDuration <= 120 {
            var k = max(Int((window.lowerBound / timeline.clipDuration).rounded(.up)), 1)
            while k < timeline.copyCount, Double(k) * timeline.clipDuration <= window.upperBound {
                let px = x(Double(k) * timeline.clipDuration, lane.width)
                context.fill(Path(CGRect(x: px - 0.5, y: lane.minY, width: 1, height: lane.height)), with: .color(.white.opacity(0.6)))
                k += 1
            }
        } else {
            let text = Text("\(timeline.copyCount) copies of \(Format.clock(timeline.clipDuration))")
                .font(.caption2).foregroundStyle(.white)
            context.draw(text, at: CGPoint(x: lane.minX + 6, y: lane.midY), anchor: .leading)
        }
    }

    private func drawPieces(_ audio: PreviewTimeline.Lane, color: Color, in lane: CGRect, context: inout GraphicsContext) {
        for (index, piece) in audio.pieces.enumerated() where piece.end >= window.lowerBound && piece.start <= window.upperBound {
            let left = max(x(piece.start, lane.width), 0)
            let right = min(x(piece.end, lane.width), lane.width)
            guard right - left >= 0.5 else { continue }
            let rect = CGRect(x: left, y: lane.minY + 2, width: right - left, height: lane.height - 4)
            // Neighbours alternate shade so each piece reads on its own.
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(index.isMultiple(of: 2) ? 1 : 0.78)))
            if piece.fadeIn > 0 {
                let a = max(x(piece.start, lane.width), 0), b = min(x(piece.start + piece.fadeIn, lane.width), lane.width)
                if b > a { context.fill(Path(CGRect(x: a, y: rect.minY, width: b - a, height: rect.height)), with: .color(.white.opacity(0.35))) }
            }
            if rect.width > 70, !piece.title.isEmpty {
                var inner = context
                inner.clip(to: Path(rect))
                inner.draw(Text(piece.title).font(.caption2).foregroundStyle(.white),
                           at: CGPoint(x: rect.minX + 5, y: rect.midY), anchor: .leading)
            }
        }
    }

    private func drawLevel(_ role: AudioRole, in lane: CGRect, context: inout GraphicsContext) {
        let samples = 160
        var path = Path()
        for i in 0...samples {
            let t = window.lowerBound + span * Double(i) / Double(samples)
            let y = lane.maxY - 3 - CGFloat(level(role, t)) * (lane.height - 6)
            let point = CGPoint(x: lane.width * CGFloat(i) / CGFloat(samples), y: y)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.4)
    }
}

// MARK: - Mix

private struct MixInspector: View {
    @Environment(LooperModel.self) private var model
    @Environment(PreviewModel.self) private var preview

    var body: some View {
        @Bindable var model = model
        Form {
            if let currentBed = model.audio.bed {
                let bed = $model.audio.bed.unwrapped(fallback: currentBed)
                Section { TrackControls(track: bed.track, crossfade: bed.wrapCrossfade, crossfadeLabel: "Wrap crossfade") }
                    header: { header(.bed) }
            }
            if let currentPlaylist = model.audio.playlist {
                let playlist = $model.audio.playlist.unwrapped(fallback: currentPlaylist)
                Section { TrackControls(track: playlist.track, crossfade: playlist.crossfade, crossfadeLabel: "Song crossfade") }
                    header: { header(.playlist) }
            }
            if model.audio.clipAudio.enabled, model.clip?.hasAudio == true {
                Section { TrackControls(track: $model.audio.clipAudio.track) }
                    header: { header(.clipAudio) }
            }
            Section {
                if model.audio.hasAudio(clipHasAudio: model.clip?.hasAudio ?? false) {
                    Text("These are the export's settings: changes here are used when you export. Mute and solo only affect the preview.")
                } else {
                    Text("No audio. Add an ambient bed or a music playlist in the main window.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .disabled(model.isExporting)
    }

    private func header(_ role: AudioRole) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(LaneStyle.color(role)).frame(width: 10, height: 10)
            Text(LaneStyle.name(role))
            Spacer()
            toggle("M", help: "Mute in the preview only", isOn: binding(\.muted, role))
            toggle("S", help: "Solo in the preview only", isOn: binding(\.soloed, role))
        }
    }

    private func toggle(_ title: String, help: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.button)
            .controlSize(.small)
            .help(help)
    }

    private func binding(_ set: ReferenceWritableKeyPath<PreviewModel, Set<AudioRole>>, _ role: AudioRole) -> Binding<Bool> {
        Binding(
            get: { preview[keyPath: set].contains(role) },
            set: { on in
                if on { preview[keyPath: set].insert(role) } else { preview[keyPath: set].remove(role) }
            })
    }
}

enum PreviewFormat {
    /// "0:29:58.40".
    static func clock(_ seconds: Double, fraction: Bool) -> String {
        let whole = Int(seconds)
        let base = String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
        guard fraction else { return base }
        return base + String(format: ".%02d", Int((seconds - Double(whole)) * 100))
    }
}
