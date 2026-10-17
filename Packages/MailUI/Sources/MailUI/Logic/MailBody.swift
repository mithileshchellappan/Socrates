import Foundation
import StudyUI
import SwiftUI

/// A mail body as the reader shows it: paragraphs, headings, list items, preformatted text and
/// rules, each an `AttributedString` with emphasis and links. Quoted earlier mail is marked
/// (`isQuoted`) and starts collapsed. Nothing in it loads anything: no images, no styles, no web
/// view; links are only http, https and mailto, and open only when clicked.
struct MailBody: Hashable, Sendable {
    var blocks: [MailBlock] = []

    var isEmpty: Bool { blocks.isEmpty }

    /// The blocks grouped for display: runs of quoted blocks become one collapsible section.
    var sections: [MailBodySection] {
        var sections: [MailBodySection] = []
        for block in blocks {
            if block.isQuoted, case .quoted(var run) = sections.last {
                run.append(block)
                sections[sections.count - 1] = .quoted(run)
            } else if block.isQuoted {
                sections.append(.quoted([block]))
            } else {
                sections.append(.block(block))
            }
        }
        return sections
    }

    /// Every block's text, joined by line breaks (tests, accessibility).
    var plainText: String {
        blocks.map { String($0.text.characters) }.joined(separator: "\n")
    }
}

enum MailBodySection: Hashable, Sendable, Identifiable {
    case block(MailBlock)
    case quoted([MailBlock])

    var id: Int {
        switch self {
        case .block(let block): block.id
        case .quoted(let blocks): -1 - (blocks.first?.id ?? 0)
        }
    }
}

struct MailBlock: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case paragraph
        case heading(Int)
        case listItem(marker: String)
        case preformatted
        case rule
    }

    var id: Int
    var kind: Kind
    var text: AttributedString
    /// List and quote nesting below the first level.
    var indent: Int = 0
    /// Part of earlier mail quoted in a reply.
    var isQuoted: Bool = false
}

/// Marks the text of a quote an item was read from (the reader underlines it dotted in the AI
/// colour).
enum FoundQuoteAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "StudyPortal.MailUI.foundQuote"
}

/// Builds `MailBody` from the sanitized HTML (docs/plan-m2.md §2.8) or from `body_text`.
enum MailBodyRenderer {
    /// The body of a message: its sanitized HTML when there is one and it parses, else its text;
    /// `quotes` underlined.
    static func render(html: String?, text: String, quotes: [String] = []) -> MailBody {
        var blocks = html.flatMap(htmlBlocks) ?? textBlocks(text)
        if blocks.isEmpty, html != nil { blocks = textBlocks(text) }
        markAttributions(&blocks)
        markQuotes(quotes, in: &blocks)
        for index in blocks.indices { blocks[index].id = index }
        return MailBody(blocks: blocks)
    }

    // MARK: HTML

    /// Blocks of a sanitized HTML fragment; nil when it is not well-formed XML.
    static func htmlBlocks(_ html: String) -> [MailBlock]? {
        var source = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        // The sanitizer writes `&#160;`; be lenient with the one named entity HTML mail loves.
        source = source.replacingOccurrences(of: "&nbsp;", with: "&#160;")
        if !source.lowercased().hasPrefix("<div") || !source.lowercased().hasSuffix("</div>") {
            source = "<div>\(source)</div>"
        }
        guard let data = source.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        let builder = HTMLBlockBuilder()
        parser.delegate = builder
        guard parser.parse(), !builder.failed else { return nil }
        return builder.finish()
    }

    /// Only these schemes become links.
    static func safeLink(_ href: String) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme != "mailto", url.host() == nil { return nil }
        return url
    }

    // MARK: Plain text

    /// Blocks of plain text: paragraphs split at blank lines, line breaks kept, "> " quoting and
    /// "-----Original Message-----" marking quoted mail, links detected.
    static func textBlocks(_ text: String) -> [MailBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MailBlock] = []
        var paragraph: [String] = []
        var paragraphDepth = 0
        var restIsQuoted = false
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard !joined.isEmpty else { return }
            let quoted = restIsQuoted || paragraphDepth > 0
            blocks.append(MailBlock(
                id: blocks.count, kind: .paragraph, text: linked(joined, detector: detector),
                indent: max(0, paragraphDepth - 1), isQuoted: quoted
            ))
        }

        for rawLine in lines {
            let (depth, line) = quoteDepth(of: rawLine)
            if !restIsQuoted, depth == 0, isOriginalMessageMarker(line) {
                flush()
                restIsQuoted = true
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                paragraphDepth = depth
                continue
            }
            if depth != paragraphDepth, !paragraph.isEmpty { flush() }
            paragraphDepth = depth
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    /// Nesting of "> " quoting and the line without it.
    static func quoteDepth(of line: String) -> (Int, String) {
        var depth = 0
        var rest = Substring(line)
        while true {
            let trimmed = rest.drop(while: { $0 == " " })
            guard trimmed.first == ">" else { break }
            depth += 1
            rest = trimmed.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return depth == 0 ? (0, line) : (depth, String(rest))
    }

    static func isOriginalMessageMarker(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard lowered.hasPrefix("--") || lowered.hasPrefix("__") else { return false }
        return lowered.contains("original message") || lowered.contains("ursprüngliche nachricht")
            || lowered.contains("originalnachricht")
    }

    /// "On Fri, 16 Oct 2026, Cy Demo wrote:", "Am 16.10.2026 um 13:37 schrieb Cy Demo:".
    static func isAttribution(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard line.count < 300, line.hasSuffix(":") else { return false }
        let lowered = line.lowercased()
        return (lowered.hasPrefix("on ") && lowered.hasSuffix("wrote:"))
            || (lowered.hasPrefix("am ") && lowered.contains("schrieb"))
            || lowered.hasSuffix("schrieb:")
    }

    /// `text` with http(s) and mailto links detected.
    static func linked(_ text: String, detector: NSDataDetector?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector else { return attributed }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let url = match.url, let safe = safeLink(url.absoluteString),
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = safe
        }
        return attributed
    }

    // MARK: Quotes

    /// The line introducing quoted mail belongs to it.
    static func markAttributions(_ blocks: inout [MailBlock]) {
        for index in blocks.indices.dropLast() where !blocks[index].isQuoted && blocks[index + 1].isQuoted {
            if isAttribution(String(blocks[index].text.characters)) { blocks[index].isQuoted = true }
        }
    }

    /// Underlines every occurrence of each quote (also across paragraphs).
    static func markQuotes(_ quotes: [String], in blocks: inout [MailBlock]) {
        let quotes = quotes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !quotes.isEmpty, !blocks.isEmpty else { return }
        var joined = ""
        var spans: [Range<Int>] = []
        var offset = 0
        for block in blocks {
            let text = String(block.text.characters)
            let count = text.count
            spans.append(offset..<(offset + count))
            joined += text
            joined += "\n"
            offset += count + 1
        }
        var style = AttributeContainer()
        style[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = Text.LineStyle(pattern: .dot, color: .ai)
        style[FoundQuoteAttribute.self] = true
        let folded = QuoteMatcher.normalized(joined)
        for quote in quotes {
            for range in QuoteMatcher.offsetRanges(of: quote, in: folded) {
                // The first block the quote reaches (spans are sorted), then onwards while it lasts.
                var low = 0
                var high = spans.count
                while low < high {
                    let middle = (low + high) / 2
                    if spans[middle].upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
                }
                var index = low
                while index < spans.count, spans[index].lowerBound < range.upperBound {
                    let span = spans[index]
                    let start = max(range.lowerBound, span.lowerBound)
                    let end = min(range.upperBound, span.upperBound)
                    if start < end {
                        var text = blocks[index].text
                        let from = text.characters.index(text.startIndex, offsetBy: start - span.lowerBound)
                        let to = text.characters.index(from, offsetBy: end - start)
                        text[from..<to].mergeAttributes(style)
                        blocks[index].text = text
                    }
                    index += 1
                }
            }
        }
    }
}

// MARK: - XMLParser delegate

/// Walks the sanitized fragment and writes blocks. Tags outside the allowlist add no structure
/// (their text is kept); containers that never belong in mail text (script, style, head, title)
/// are skipped whole.
private final class HTMLBlockBuilder: NSObject, XMLParserDelegate {
    private(set) var failed = false
    private var blocks: [MailBlock] = []
    private var current = AttributedString()
    private var kind: MailBlock.Kind = .paragraph
    private var bold = 0
    private var italic = 0
    private var underline = 0
    private var strike = 0
    private var code = 0
    private var links: [URL?] = []
    private var lists: [(ordered: Bool, counter: Int)] = []
    private var pendingMarker: String?
    private var quoteDepth = 0
    private var preDepth = 0
    private var skipDepth = 0
    private var cells = 0
    private var endsWithSpace = true

    private static let blockTags: Set<String> = [
        "div", "p", "blockquote", "pre", "ul", "ol", "li", "table", "thead", "tbody", "tr", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]
    private static let skippedTags: Set<String> = ["script", "style", "head", "title", "template", "noscript", "iframe", "object"]

    func finish() -> [MailBlock] {
        flush()
        return blocks
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        failed = true
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let tag = elementName.lowercased()
        if Self.skippedTags.contains(tag) || skipDepth > 0 {
            skipDepth += 1
            return
        }
        if Self.blockTags.contains(tag) { flush() }
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            kind = .heading(Int(tag.dropFirst()) ?? 3)
        case "pre":
            preDepth += 1
            kind = .preformatted
        case "blockquote":
            quoteDepth += 1
        case "ul":
            lists.append((false, 0))
        case "ol":
            lists.append((true, 0))
        case "li":
            if lists.isEmpty { lists.append((false, 0)) }
            lists[lists.count - 1].counter += 1
            let list = lists[lists.count - 1]
            pendingMarker = list.ordered ? "\(list.counter)." : (lists.count > 1 ? "◦" : "•")
        case "tr":
            cells = 0
        case "td", "th":
            if cells > 0 { append(" · ", plain: true) }
            cells += 1
            if tag == "th" { bold += 1 }
        case "hr":
            blocks.append(MailBlock(id: blocks.count, kind: .rule, text: AttributedString(), indent: indent, isQuoted: quoteDepth > 0))
        case "br":
            current.append(AttributedString("\n"))
            endsWithSpace = true
        case "a":
            links.append(attributeDict.first { $0.key.lowercased() == "href" }.flatMap { MailBodyRenderer.safeLink($0.value) })
        case "b", "strong":
            bold += 1
        case "i", "em":
            italic += 1
        case "u":
            underline += 1
        case "s", "strike", "del":
            strike += 1
        case "code", "tt", "kbd":
            code += 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = elementName.lowercased()
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        if Self.blockTags.contains(tag) { flush() }
        switch tag {
        case "pre":
            preDepth = max(0, preDepth - 1)
        case "blockquote":
            quoteDepth = max(0, quoteDepth - 1)
        case "ul", "ol":
            if !lists.isEmpty { lists.removeLast() }
        case "li":
            pendingMarker = nil
        case "a":
            if !links.isEmpty { links.removeLast() }
        case "b", "strong":
            bold = max(0, bold - 1)
        case "th":
            bold = max(0, bold - 1)
        case "i", "em":
            italic = max(0, italic - 1)
        case "u":
            underline = max(0, underline - 1)
        case "s", "strike", "del":
            strike = max(0, strike - 1)
        case "code", "tt", "kbd":
            code = max(0, code - 1)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        if preDepth > 0 {
            append(string, plain: false)
            endsWithSpace = string.last?.isWhitespace ?? endsWithSpace
            return
        }
        // HTML whitespace: runs collapse to one space; none at the start of a block.
        var collapsed = ""
        var lastWasSpace = endsWithSpace
        for character in string {
            if character.isWhitespace, character != "\u{00A0}" {
                if !lastWasSpace { collapsed.append(" ") }
                lastWasSpace = true
            } else {
                collapsed.append(character)
                lastWasSpace = false
            }
        }
        guard !collapsed.isEmpty else { return }
        append(collapsed, plain: false)
        endsWithSpace = lastWasSpace
    }

    private var indent: Int {
        max(0, lists.count - 1) + max(0, quoteDepth - 1)
    }

    private func append(_ text: String, plain: Bool) {
        var attributes = AttributeContainer()
        if !plain {
            var intent: InlinePresentationIntent = []
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if code > 0 || preDepth > 0 { intent.insert(.code) }
            if strike > 0 { intent.insert(.strikethrough) }
            if !intent.isEmpty { attributes.inlinePresentationIntent = intent }
            if underline > 0 {
                attributes[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
            }
            if let link = links.last ?? nil { attributes.link = link }
        }
        current.append(AttributedString(text, attributes: attributes))
    }

    /// Ends the block being written (when it has text).
    private func flush() {
        defer {
            current = AttributedString()
            kind = .paragraph
            endsWithSpace = true
            if preDepth > 0 { kind = .preformatted }
        }
        let text = String(current.characters)
        guard text.contains(where: { !$0.isWhitespace }) else { return }
        var trimmed = current
        if kind != .preformatted {
            while let last = trimmed.characters.last, last.isWhitespace {
                trimmed.characters.removeLast()
            }
            while let first = trimmed.characters.first, first.isWhitespace {
                trimmed.characters.removeFirst()
            }
        } else {
            while let last = trimmed.characters.last, last == "\n" {
                trimmed.characters.removeLast()
            }
        }
        var blockKind = kind
        if let marker = pendingMarker, kind == .paragraph {
            blockKind = .listItem(marker: marker)
            pendingMarker = nil
        }
        let continuation = lists.isEmpty ? 0 : (blockKind == .paragraph ? 1 : 0)
        blocks.append(MailBlock(
            id: blocks.count, kind: blockKind, text: trimmed, indent: indent + continuation, isQuoted: quoteDepth > 0
        ))
    }
}
