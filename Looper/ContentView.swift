import AppKit
import LooperCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window: clip, duration, output, export. All state and rules live in
/// `LooperModel` (LooperCore); these views display it and forward actions.
struct ContentView: View {
    @Environment(LooperModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        Form {
            ClipSection()
            DurationSection()
            AudioSection()
            OutputSection()
        }
        .formStyle(.grouped)
        // A fixed-size, resizable window: the form scrolls when the audio options make
        // it taller than the window, instead of the window growing off the screen.
        .frame(minWidth: Layout.minWidth, idealWidth: Layout.width, maxWidth: .infinity,
               minHeight: Layout.minHeight, idealHeight: Layout.height, maxHeight: .infinity)
        // Export, progress and results stay pinned at the bottom, always in view.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                ExportSection()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isExporting else { return false }
            Task { await model.loadClip(from: url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .modifier(ExportFeedback())
    }
}

/// The main window's size (content area, below the title bar), matched to the
/// user's reference screenshot: about 790 × 730 pt including the title bar. Tall
/// enough for the clip, length, output and export without scrolling; the audio
/// options scroll.
enum Layout {
    static let width: CGFloat = 790
    static let height: CGFloat = 700
    static let minWidth: CGFloat = 560
    static let minHeight: CGFloat = 520
}

// MARK: - Clip

private struct ClipSection: View {
    @Environment(LooperModel.self) private var model
    @State private var isChoosing = false

    var body: some View {
        Section("Loop clip") {
            HStack(alignment: .top, spacing: 14) {
                poster
                VStack(alignment: .leading, spacing: 4) {
                    if let clip = model.clip {
                        Text(clip.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text(details(clip)).font(.callout).foregroundStyle(.secondary)
                        if !clip.isConstantFrameRate {
                            Label("Variable frame rate: frame counts are approximate.", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    } else if model.isLoadingClip {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Drop a seamless loop clip here").font(.headline)
                        Text("or choose one. Any resolution and frame rate; one video track.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = model.clipError {
                        Label(error, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red)
                    }
                    Button(model.clip == nil ? "Choose Clip…" : "Choose Another…") { isChoosing = true }
                        .disabled(model.isExporting)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { Task { await model.loadClip(from: url) } }
        }
    }

    private var poster: some View {
        Group {
            if let poster = model.poster {
                Image(decorative: poster.cgImage, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 160, height: 90)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func details(_ clip: ClipInfo) -> String {
        let fps = clip.nominalFrameRate.formatted(.number.precision(.fractionLength(0...3)))
        var parts = [
            "\(Int(clip.naturalSize.width))×\(Int(clip.naturalSize.height))",
            clip.codec,
            "\(fps) fps",
            "\(clip.frameCount) frames (\(Format.clock(clip.duration.seconds)))",
        ]
        parts.append(clip.hasAudio ? "has audio" : "no audio")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Duration

private struct DurationSection: View {
    @Environment(LooperModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Length") {
            Picker("Length", selection: $model.durationChoice) {
                Text("1 hour").tag(LooperModel.DurationChoice.preset(.oneHour))
                Text("3 hours").tag(LooperModel.DurationChoice.preset(.threeHours))
                Text("8 hours").tag(LooperModel.DurationChoice.preset(.eightHours))
                Text("Custom").tag(LooperModel.DurationChoice.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.durationChoice == .custom {
                TextField("Custom length", text: $model.customDuration, prompt: Text("h:mm:ss"))
                    .help("For example 1:00:10, 90:00, 8h or 45m")
            }
            if let error = model.targetError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let summary = model.planSummary {
                Text(summary).foregroundStyle(.secondary)
            }
        }
        .disabled(model.isExporting)
    }
}

// MARK: - Audio

private struct AudioSection: View {
    @Environment(LooperModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            BedRow()
            if let bed = Binding($model.audio.bed) {
                TrackControls(track: bed.track, crossfade: bed.wrapCrossfade, crossfadeLabel: "Wrap crossfade")
            }
            PlaylistRow()
            if let playlist = Binding($model.audio.playlist) {
                TrackControls(track: playlist.track, crossfade: playlist.crossfade, crossfadeLabel: "Song crossfade")
            }
            Toggle("Use the clip's own audio", isOn: $model.audio.clipAudio.enabled)
                .disabled(!(model.clip?.hasAudio ?? false))
                .help("Off by default: a 30 s sound loop repeats audibly. A long bed usually sounds better.")
            if model.audio.clipAudio.enabled, model.clip?.hasAudio == true {
                TrackControls(track: $model.audio.clipAudio.track)
            }
            ForEach(model.audioNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.audioError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("Mixed to AAC 48 kHz stereo. Leave everything off for a silent video.")
        }
        .disabled(model.isExporting)
    }
}

private struct BedRow: View {
    @Environment(LooperModel.self) private var model
    @State private var isChoosing = false

    var body: some View {
        @Bindable var model = model
        LabeledContent("Ambient bed") {
            HStack {
                if let bed = model.bedItem {
                    Text("\(bed.name) · \(Format.clock(bed.seconds))").lineLimit(1).truncationMode(.middle)
                    Button("Remove", systemImage: "xmark.circle.fill") { model.removeBed() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
                Button("Choose…") { isChoosing = true }
                    .help("An audio file, or a video with sound (such as a screen recording of a sound website). Only the sound is used.")
            }
        }
        // Videos too: their sound becomes the bed and the picture is ignored.
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.audio, .audiovisualContent]) { result in
            if case .success(let url) = result { Task { await model.chooseBed(url) } }
        }
        if model.bedSilence != nil {
            Toggle("Trim silence at the start and end", isOn: $model.trimBedSilence)
                .help("A recording often starts with a moment of silence, which would play every time the bed loops.")
                .padding(.leading, 16)
            if let summary = model.bedSilenceSummary {
                Text(summary).font(.callout).foregroundStyle(.secondary).padding(.leading, 16)
            }
        }
    }
}

private struct PlaylistRow: View {
    @Environment(LooperModel.self) private var model
    @State private var isChoosing = false

    var body: some View {
        LabeledContent("Music playlist") {
            HStack {
                if let summary = model.playlistSummary, let folder = model.audio.playlist?.folder {
                    Text("\(folder.lastPathComponent) · \(summary)").lineLimit(1).truncationMode(.middle)
                    Button("Remove", systemImage: "xmark.circle.fill") { model.removePlaylist() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
                Button("Choose Folder…") { isChoosing = true }
            }
        }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await model.choosePlaylist(url) } }
        }
        if !model.playlistItems.isEmpty {
            DisclosureGroup("Songs, in play order") {
                ForEach(Array(model.playlistItems.enumerated()), id: \.offset) { index, item in
                    HStack {
                        Text("\(index + 1). \(item.name)").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Format.clock(item.seconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// Volume, fades and (optionally) crossfade for one audio track.
struct TrackControls: View {
    @Binding var track: AudioTrackSettings
    var crossfade: Binding<Double>? = nil
    var crossfadeLabel = "Crossfade"

    var body: some View {
        LabeledContent("Volume") {
            HStack {
                Slider(value: $track.volume, in: 0...1)
                Text(Format.percent(Double(track.volume))).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.leading, 16)
        LabeledContent("Fade in / out") {
            HStack(spacing: 6) {
                SecondsField(value: $track.fadeIn)
                Text("/").foregroundStyle(.secondary)
                SecondsField(value: $track.fadeOut)
            }
        }
        .padding(.leading, 16)
        if let crossfade {
            LabeledContent(crossfadeLabel) { SecondsField(value: crossfade) }
                .padding(.leading, 16)
        }
    }
}

struct SecondsField: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 2) {
            TextField("Seconds", value: Binding(get: { value }, set: { value = max(0, $0) }),
                      format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Text("s").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Output

private struct OutputSection: View {
    @Environment(LooperModel.self) private var model
    @State private var isChoosing = false

    var body: some View {
        Section("Output") {
            LabeledContent("Folder") {
                HStack {
                    Text(model.outputFolder.map(Format.path) ?? "None")
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { isChoosing = true }
                }
            }
            if let url = model.outputURL {
                LabeledContent("File") {
                    Text(relativePath(url)).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                }
            }
            if let bytes = model.estimatedBytes {
                LabeledContent("Estimated size") {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).foregroundStyle(.secondary)
                }
            }
            if let check = model.spaceCheck, let message = check.message {
                Label(message, systemImage: check.level == .insufficient ? "xmark.octagon" : "exclamationmark.triangle")
                    .foregroundStyle(check.level == .insufficient ? .red : .orange)
            }
        }
        .disabled(model.isExporting)
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.outputFolder = url }
        }
    }

    private func relativePath(_ url: URL) -> String {
        guard let folder = model.outputFolder else { return url.path }
        let prefix = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

// MARK: - Export

private struct ExportSection: View {
    @Environment(LooperModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var confirmReplace = false
    @State private var confirmCancel = false

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                idle
            case .exporting:
                exporting
            case .finished(let url):
                result("Done", detail: url.lastPathComponent, systemImage: "checkmark.circle.fill", color: .green) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            case .failed(let message):
                result("Export failed", detail: message, systemImage: "xmark.octagon.fill", color: .red) { EmptyView() }
            case .cancelled:
                result("Export cancelled", detail: "No file was left behind.", systemImage: "stop.circle", color: .secondary) { EmptyView() }
            }
        }
        .confirmationDialog("“\(model.outputURL?.lastPathComponent ?? "video.mp4")” already exists in this folder.",
                            isPresented: $confirmReplace) {
            Button("Replace", role: .destructive) { model.startExport(replacing: true) }
            Button("Keep Both") { model.startExport(replacing: false) }
        } message: {
            Text("Keep Both saves the new video as “video 2.mp4”.")
        }
        .alert("Cancel the export?", isPresented: $confirmCancel) {
            Button("Keep Exporting", role: .cancel) {}
            Button("Cancel Export", role: .destructive) { model.cancelExport() }
        } message: {
            Text("The partly written video will be deleted.")
        }
    }

    private var idle: some View {
        HStack {
            if let reason = model.exportBlockedReason {
                Text(reason).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Preview…") { openWindow(id: "preview") }
                .help("Play the video with its audio before exporting. Nothing is written to disk.")
                .disabled(model.clip == nil || model.target == nil)
            Button("Export") {
                if model.outputExists { confirmReplace = true } else { model.startExport() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canExport)
        }
    }

    private var exporting: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: model.progress?.fractionCompleted ?? 0)
            HStack {
                Text(Format.percent(model.progress?.fractionCompleted ?? 0)).monospacedDigit()
                Text(Format.remaining(model.progress?.estimatedTimeRemaining)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    // Only confirm once there's real work to lose.
                    if (model.exportElapsed ?? 0) > 60 { confirmCancel = true } else { model.cancelExport() }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func result<Actions: View>(_ title: String, detail: String, systemImage: String, color: Color,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } icon: {
                Image(systemName: systemImage).foregroundStyle(color)
            }
            Spacer()
            actions()
            Button("OK") { model.dismissResult() }.keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Formatting

enum Format {
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "about 3 min left", "less than a minute left", or "estimating…".
    static func remaining(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "estimating…" }
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 { return "about \(minutes) min left" }
        return "about \(Self.clock(seconds)) left"
    }

    /// Path with the home folder shown as "~".
    static func path(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

#Preview {
    ContentView().environment(LooperModel())
}
