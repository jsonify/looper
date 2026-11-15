import Foundation

/// What a job's video shows, typed by the user and used by the channel templates:
/// `{scene}`, `{mood}` and `{elements}`.
public struct SceneDetails: Codable, Equatable, Sendable {
    /// "Rainy Log Cabin".
    public var scene: String
    /// "cozy". May be empty; templates that need it are skipped.
    public var mood: String
    /// "rain", "fireplace", "distant thunder". May be empty.
    public var elements: [String]

    public init(scene: String = "", mood: String = "", elements: [String] = []) {
        self.scene = scene
        self.mood = mood
        self.elements = elements
    }

    /// Details pre-filled from a clip file name: "cabin_rain_loop_30s_v2.mp4" → scene
    /// "Cabin Rain". Words that describe the file rather than the scene (loop, 30s, v2,
    /// 1080p, 4k…) are dropped.
    public init(suggestedFor clip: URL) {
        self.init(scene: Self.sceneName(fromFileName: clip.deletingPathExtension().lastPathComponent))
    }

    private enum CodingKeys: String, CodingKey { case scene, mood, elements }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? ""
        mood = try c.decodeIfPresent(String.self, forKey: .mood) ?? ""
        elements = try c.decodeIfPresent([String].self, forKey: .elements) ?? []
    }

    static func sceneName(fromFileName name: String) -> String {
        let fileWords: Set<String> = ["loop", "loops", "seamless", "hd", "uhd", "final", "copy", "clip"]
        let words = name.split(whereSeparator: { " _-.".contains($0) }).map(String.init).filter { word in
            let lower = word.lowercased()
            if fileWords.contains(lower) { return false }
            // 30s, 30fps, 1080p, 4k, v2, 001…
            if lower.wholeMatch(of: /v?\d+(s|sec|fps|p|k)?/) != nil { return false }
            return true
        }
        guard !words.isEmpty else { return name }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
