import Foundation

/// Where exports go. The layout matches the spec's per-job folders, so M4's versions
/// slot straight in:
///
///     <output folder>/<clip name>/<version name>/video.mp4
///
/// A `Version`'s name ("8h Sleep") names its folder; unnamed versions and the M2
/// single export use the duration ("8h", "1h30m"). `Job` and `JobRunner` build on this.
public enum OutputLayout {
    public static let videoFileName = "video.mp4"

    public static func videoURL(in outputFolder: URL, clip: URL, versionName: String) -> URL {
        outputFolder
            .appendingPathComponent(folderName(forClip: clip), isDirectory: true)
            .appendingPathComponent(safeName(versionName), isDirectory: true)
            .appendingPathComponent(videoFileName)
    }

    /// The clip's file name without extension, made safe for a folder name.
    public static func folderName(forClip clip: URL) -> String {
        safeName(clip.deletingPathExtension().lastPathComponent)
    }

    /// "8h", "45m", "1h30m", "1h0m10s", "30s": short, sortable and valid in file names
    /// (no colons, which Finder shows as slashes).
    public static func versionName(for target: TargetDuration) -> String {
        let h = target.seconds / 3600, m = target.seconds / 60 % 60, s = target.seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 || (h > 0 && s > 0) { parts.append("\(m)m") }
        if s > 0 { parts.append("\(s)s") }
        return parts.joined()
    }

    /// `url` if nothing is there yet, otherwise "video 2.mp4", "video 3.mp4", ...
    public static func nextAvailable(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the folder in Finder.
        let visible = cleaned.drop { $0 == "." }
        return visible.isEmpty ? "Untitled" : String(visible)
    }
}
