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
            OutputSection()
            ExportSection()
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
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
    @State private var confirmReplace = false
    @State private var confirmCancel = false

    var body: some View {
        Section {
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
