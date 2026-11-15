import Foundation

/// What each placeholder stands for in one version's kit.
public struct PlaceholderValues: Equatable, Sendable {
    public var values: [Placeholder: String]

    public init(_ values: [Placeholder: String]) {
        self.values = values
    }

    public init(channel: Channel, job: Job, version: Version) {
        let duration = version.duration.seconds
        values = [
            .scene: job.scene.scene.trimmed,
            .mood: job.scene.mood.trimmed,
            .elements: Self.list(job.scene.elements),
            .hours: Self.hours(duration),
            .duration: Self.spelledOut(duration),
            .mode: version.mode.trimmed,
            .channel: channel.name.trimmed,
            // Only versions that actually play music may mention it.
            .music: version.audio.playlist == nil ? "" : channel.music.trimmed,
        ]
    }

    public subscript(_ placeholder: Placeholder) -> String { values[placeholder] ?? "" }

    /// `text` with its placeholders filled, or nil when one of them is empty for this
    /// version (so "{mood} Rain" never becomes " Rain"); with `skippingEmpty` false, empty
    /// values are simply left out. In titles, filled values get capitalised words to match
    /// the Title Case patterns ("cozy" → "Cozy").
    public func fill(_ text: String, titleCase: Bool = false,
                     skippingEmpty: Bool = true) throws(TemplateText.ParseError) -> String? {
        var result = ""
        for piece in try TemplateText.pieces(of: text) {
            switch piece {
            case .literal(let literal):
                result += literal
            case .placeholder(let name):
                guard let placeholder = Placeholder(rawValue: name) else { throw .unknownPlaceholder(name) }
                let value = self[placeholder]
                if value.isEmpty && skippingEmpty { return nil }
                result += titleCase ? Self.capitalisingWords(value) : value
            }
        }
        return result
    }

    /// "rain", "fireplace", "distant thunder" → "rain, fireplace & distant thunder".
    static func list(_ items: [String]) -> String {
        let items = items.map(\.trimmed).filter { !$0.isEmpty }
        guard let last = items.last else { return "" }
        return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " & " + last
    }

    /// 10800 → "3", 5400 → "1.5", 2700 → "0.75".
    static func hours(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600)" }
        var text = String(format: "%.2f", Double(seconds) / 3600)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// 10800 → "3 Hours", 5400 → "1 Hour 30 Minutes", 3610 → "1 Hour 10 Seconds".
    static func spelledOut(_ seconds: Int) -> String {
        let parts = [(seconds / 3600, "Hour"), (seconds / 60 % 60, "Minute"), (seconds % 60, "Second")]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " ")
    }

    /// Upper-cases the first letter of each word, leaving the rest as typed ("iPad" stays).
    static func capitalisingWords(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Upper-cases the first letter, for lines that start with a placeholder.
    static func capitalisingFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
