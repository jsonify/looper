import Foundation

/// One thing wrong with a channel, with where it is, e.g.
/// `titles.byMode.Sleep[2]: uses {senes}, which isn't a placeholder`.
public struct ChannelProblem: Equatable, Sendable, CustomStringConvertible {
    public var field: String
    public var message: String

    public init(_ field: String, _ message: String) {
        self.field = field
        self.message = message
    }

    public var description: String { "\(field): \(message)" }
}

public struct ChannelValidationError: Error, Equatable, LocalizedError {
    public var channel: String
    public var problems: [ChannelProblem]

    public var errorDescription: String? {
        "Channel “\(channel)” has \(problems.count == 1 ? "a problem" : "\(problems.count) problems"):\n"
            + problems.map { "• \($0)" }.joined(separator: "\n")
    }
}

extension Channel {
    /// Everything wrong with the channel; empty when it's ready to use. Checks all of it
    /// at once, so a hand-edited file can be fixed in one pass.
    public var problems: [ChannelProblem] {
        var problems: [ChannelProblem] = []
        func check(_ condition: Bool, _ field: String, _ message: String) {
            if !condition { problems.append(ChannelProblem(field, message)) }
        }

        check(Self.isValidID(id), "id", "use lowercase letters, digits and dashes, e.g. “rainfall-hours”")
        check(!name.trimmingCharacters(in: .whitespaces).isEmpty, "name", "is empty")
        check(Self.isHexColor(brand.textColor), "brand.textColor", "“\(brand.textColor)” isn't a colour like #FFFFFF")
        check(Self.isHexColor(brand.accentColor), "brand.accentColor", "“\(brand.accentColor)” isn't a colour like #FFFFFF")
        check(!brand.font.trimmingCharacters(in: .whitespaces).isEmpty, "brand.font", "is empty")

        // Templates: balanced braces and known placeholders only.
        let templated: [(String, ModePools)] = [("titles", titles), ("hooks", hooks), ("hear", hear), ("perfectFor", perfectFor)]
        for (field, pools) in templated {
            for entry in pools.labelledEntries {
                let label = "\(field).\(entry.label)"
                check(!entry.text.trimmingCharacters(in: .whitespaces).isEmpty, label, "is empty")
                do { _ = try TemplateText.placeholders(in: entry.text) } catch { problems.append(ChannelProblem(label, error.description)) }
            }
        }
        do { _ = try TemplateText.placeholders(in: footer) } catch { problems.append(ChannelProblem("footer", error.description)) }

        // Every default version's mode needs the required pools (own or shared).
        check(!versions.isEmpty, "versions", "add at least one default version")
        var folders = Set<String>()
        for (index, version) in versions.enumerated() {
            let label = "versions[\(index)]"
            if !folders.insert(version.folderName.lowercased()).inserted {
                problems.append(ChannelProblem(label, "two versions are named “\(version.folderName)”"))
            }
            let mode = version.mode.isEmpty ? "(no mode)" : "“\(version.mode)”"
            for (field, pools) in [("titles", titles), ("hooks", hooks), ("perfectFor", perfectFor)] {
                check(!pools.pool(for: version.mode).isEmpty, label, "mode \(mode) has no \(field); add a shared or per-mode pool")
            }
        }

        // Tags end up comma-separated in tags.txt; YouTube rejects angle brackets.
        let tagged: [(String, String)] = coreTags.enumerated().map { ("coreTags[\($0.offset)]", $0.element) }
            + modeTags.labelledEntries.map { ("modeTags.\($0.label)", $0.text) }
        for (label, tag) in tagged {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            check(!trimmed.isEmpty, label, "is empty")
            check(!tag.contains(where: { ",<>".contains($0) }), label, "“\(tag)” can't contain commas or angle brackets")
        }

        check(hashtags.count <= 3, "hashtags", "use at most 3 (YouTube shows the first three)")
        for (index, tag) in hashtags.enumerated() {
            check(tag.hasPrefix("#") && tag.count > 1 && !tag.contains(where: \.isWhitespace),
                  "hashtags[\(index)]", "“\(tag)” must start with # and have no spaces")
        }
        return problems
    }

    /// Throws `ChannelValidationError` listing every problem, if there are any.
    public func validate() throws(ChannelValidationError) {
        let found = problems
        if !found.isEmpty { throw ChannelValidationError(channel: name.isEmpty ? id : name, problems: found) }
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix("-") && !id.hasSuffix("-")
            && id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    static func isHexColor(_ text: String) -> Bool {
        text.count == 7 && text.hasPrefix("#") && text.dropFirst().allSatisfy(\.isHexDigit)
    }
}
