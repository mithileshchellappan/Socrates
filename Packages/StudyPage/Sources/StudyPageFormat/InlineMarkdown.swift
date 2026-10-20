import Foundation
import StudyCore

// The inline part of a block: styled words, citation chips and inline math, in order. Markers and
// `$…$` are cut out before the Markdown parse (so a `_` or `*` inside a formula or a marker is
// never read as emphasis) and come back as runs of their own. Links keep their text only (no web
// in the notes), raw HTML stays text.

/// A run of a block's words.
public enum InlineRun: Hashable, Sendable {
    case text(String, InlineStyle)
    /// A citation marker (`[[9a7d94d1 S13]]`), drawn as a chip.
    case citation(ChatCitation)
    /// Inline math (LaTeX, math mode), drawn as a formula.
    case math(String)

    /// The run's words (a citation's label, a formula's LaTeX).
    public var plainText: String {
        switch self {
        case .text(let text, _): text
        case .citation(let citation): LectureNotesText.label(citation)
        case .math(let latex): InlineMath.unicode(latex) ?? latex
        }
    }
}

/// Character styles of a text run.
public struct InlineStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = InlineStyle(rawValue: 1)
    public static let italic = InlineStyle(rawValue: 2)
    public static let code = InlineStyle(rawValue: 4)
    public static let strikethrough = InlineStyle(rawValue: 8)
}

public enum InlineMarkdown {
    /// The runs of one block's text. A soft line break reads as a space; `math` off keeps `$` as
    /// text.
    public static func runs(_ text: String, math: Bool = true) -> [InlineRun] {
        var tokens: [InlineRun] = []
        let source = placeholders(in: text.replacingOccurrences(of: "\n", with: " "), math: math, tokens: &tokens)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        var runs: [InlineRun] = []
        func append(_ text: String, _ style: InlineStyle) {
            guard !text.isEmpty else { return }
            if case .text(let last, let lastStyle)? = runs.last, lastStyle == style {
                runs[runs.count - 1] = .text(last + text, style)
            } else {
                runs.append(.text(text, style))
            }
        }
        for run in parsed.runs {
            var style: InlineStyle = []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { style.insert(.bold) }
                if intent.contains(.emphasized) { style.insert(.italic) }
                if intent.contains(.code) { style.insert(.code) }
                if intent.contains(.strikethrough) { style.insert(.strikethrough) }
            }
            let words = String(parsed[run.range].characters)
            var pending = ""
            for scalar in words.unicodeScalars {
                let value = Int(scalar.value)
                if value >= placeholderBase, value < placeholderBase + tokens.count {
                    append(pending, style)
                    pending = ""
                    runs.append(tokens[value - placeholderBase])
                } else {
                    pending.unicodeScalars.append(scalar)
                }
            }
            append(pending, style)
        }
        return runs
    }

    /// The block's plain words (chips as their labels, formulas as text).
    public static func plainText(_ text: String) -> String {
        runs(text).map(\.plainText).joined()
    }

    /// Private-use characters stand for the tokens while the Markdown is parsed.
    static let placeholderBase = 0xE000

    /// `text` with markers and inline math replaced by placeholders (code spans left alone).
    static func placeholders(in text: String, math: Bool, tokens: inout [InlineRun]) -> String {
        var result = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            // A code span is copied as it is (its backticks too), never searched for markers or math.
            if let tick = rest.firstIndex(of: "`") {
                result += replacing(rest[..<tick], math: math, tokens: &tokens)
                let run = rest[tick...].prefix { $0 == "`" }
                let after = rest[run.endIndex...]
                if let close = after.range(of: String(run)) {
                    result += rest[tick..<close.upperBound]
                    rest = rest[close.upperBound...]
                } else {
                    result += run
                    rest = after
                }
            } else {
                result += replacing(rest, math: math, tokens: &tokens)
                break
            }
        }
        return result
    }

    private static func replacing(_ text: Substring, math: Bool, tokens: inout [InlineRun]) -> String {
        var result = ""
        for piece in ChatCitation.pieces(of: String(text)) {
            switch piece {
            case .citation(let citation):
                result.unicodeScalars.append(placeholder(tokens.count))
                tokens.append(.citation(citation))
            case .text(let words):
                result += math ? replacingMath(words, tokens: &tokens) : words
            }
        }
        return result
    }

    private static func placeholder(_ index: Int) -> Unicode.Scalar {
        Unicode.Scalar(UInt32(placeholderBase + min(index, 0x18FF))) ?? "?"
    }

    /// Inline math by Pandoc's rule: `$` followed by a non-space, closed by a `$` after a
    /// non-space that no digit follows; `\$` is a dollar.
    private static func replacingMath(_ text: String, tokens: inout [InlineRun]) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "$" {
                result += "\\$"
                index += 2
                continue
            }
            guard character == "$" else {
                result.append(character)
                index += 1
                continue
            }
            let display = index + 1 < characters.count && characters[index + 1] == "$"
            let open = index + (display ? 2 : 1)
            if let close = closingDollar(characters, from: open, display: display) {
                let latex = String(characters[open..<close]).trimmingCharacters(in: .whitespaces)
                result.unicodeScalars.append(placeholder(tokens.count))
                tokens.append(.math(latex))
                index = close + (display ? 2 : 1)
            } else {
                // A price, a lone dollar: escaped, so the Markdown parse keeps it.
                result += "\\$"
                index += 1
            }
        }
        return result
    }

    private static func closingDollar(_ characters: [Character], from open: Int, display: Bool) -> Int? {
        guard open < characters.count, !characters[open].isWhitespace, characters[open] != "$" else { return nil }
        var index = open
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == "$" {
                if display {
                    guard index + 1 < characters.count, characters[index + 1] == "$" else { return nil }
                    return index > open ? index : nil
                }
                let before = characters[index - 1]
                let after = index + 1 < characters.count ? characters[index + 1] : nil
                if index > open, !before.isWhitespace, !(after?.isNumber ?? false) { return index }
                return nil
            }
            index += 1
        }
        return nil
    }
}
