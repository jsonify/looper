import Foundation

/// The placeholders channel templates may use. Anything else in braces is an error when
/// the channel loads, so a typo never ends up in a published title.
public enum Placeholder: String, CaseIterable, Sendable {
    /// "Rainy Log Cabin" (the job's scene field).
    case scene
    /// "cozy" (the job's mood field).
    case mood
    /// "rain, fireplace & distant thunder" (the job's elements).
    case elements
    /// "3".
    case hours
    /// "3 Hours", "1 Hour 30 Minutes".
    case duration
    /// The version's mode, e.g. "Sleep".
    case mode
    /// The channel's name.
    case channel
    /// "Soft Piano" when the version has a playlist, otherwise empty.
    case music
}

/// Reading `{placeholder}`s out of template text.
public enum TemplateText {
    public enum Piece: Equatable, Sendable {
        case literal(String)
        case placeholder(String)
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unclosedBrace
        case strayClosingBrace
        case unknownPlaceholder(String)

        public var description: String {
            switch self {
            case .unclosedBrace: "has a “{” with no matching “}”"
            case .strayClosingBrace: "has a “}” with no matching “{”"
            case .unknownPlaceholder(let name):
                "uses {\(name)}, which isn't a placeholder (use "
                    + Placeholder.allCases.map { "{\($0.rawValue)}" }.joined(separator: ", ") + ")"
            }
        }
    }

    /// Splits `text` into literal runs and placeholder names. Throws on unbalanced braces;
    /// placeholder names are returned as written, unchecked.
    public static func pieces(of text: String) throws(ParseError) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        var name: String?
        for character in text {
            switch (character, name) {
            case ("{", nil):
                if !literal.isEmpty { pieces.append(.literal(literal)); literal = "" }
                name = ""
            case ("{", _?):
                throw .unclosedBrace
            case ("}", nil):
                throw .strayClosingBrace
            case ("}", let current?):
                pieces.append(.placeholder(current))
                name = nil
            case (_, let current?):
                name = current + String(character)
            case (_, nil):
                literal.append(character)
            }
        }
        if name != nil { throw .unclosedBrace }
        if !literal.isEmpty { pieces.append(.literal(literal)) }
        return pieces
    }

    /// The placeholders `text` uses. Throws on unbalanced braces or unknown names.
    public static func placeholders(in text: String) throws(ParseError) -> [Placeholder] {
        var found: [Placeholder] = []
        for case .placeholder(let name) in try pieces(of: text) {
            guard let placeholder = Placeholder(rawValue: name) else { throw .unknownPlaceholder(name) }
            found.append(placeholder)
        }
        return found
    }
}
