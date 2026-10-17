import Foundation

/// Turns mail HTML into the safe fragment of docs/plan-m2.md §2.8: one `<div>` around a
/// well-formed XML fragment over a small tag allowlist (`div p br span b strong i em u s a ul ol li
/// blockquote pre code h1–h6 table thead tbody tr td th hr`), `href` on `a` as the only attribute
/// and only with http, https or mailto URLs, entities only `&lt; &gt; &amp; &quot;` (other
/// characters as UTF-8). No images, styles, scripts, forms, iframes, comments or event handlers:
/// nothing in the output loads anything. A single byte-level pass, no WebKit, no
/// `NSAttributedString(html:)`, no network.
public enum HTMLSanitizer {
    /// The sanitized fragment for `html`.
    public static func sanitize(_ html: String) -> String {
        var input = Array(html.utf8)
        return input.withUnsafeMutableBufferPointer { buffer in
            var sanitizer = Sanitizer(input: UnsafeBufferPointer(buffer))
            return sanitizer.run()
        }
    }

    /// Readable plain text of a sanitized fragment: paragraphs, list bullets, quoted blocks with
    /// "> ", table cells separated by tabs; link targets left out (the text and the HTML say the
    /// same).
    public static func text(fromSanitized fragment: String) -> String {
        var input = Array(fragment.utf8)
        return input.withUnsafeMutableBufferPointer { buffer in
            var extractor = TextExtractor(input: UnsafeBufferPointer(buffer))
            return extractor.run()
        }
    }

    /// Tags allowed in the output.
    public static let allowedTags: Set<String> = [
        "div", "p", "br", "span", "b", "strong", "i", "em", "u", "s", "a", "ul", "ol", "li", "blockquote", "pre", "code",
        "h1", "h2", "h3", "h4", "h5", "h6", "table", "thead", "tbody", "tr", "td", "th", "hr",
    ]
}

// MARK: - Tags

/// Output tags; raw values index `names`.
private enum Tag: UInt8 {
    case div, p, br, span, b, strong, i, em, u, s, a, ul, ol, li, blockquote, pre, code
    case h1, h2, h3, h4, h5, h6, table, thead, tbody, tr, td, th, hr

    static let names: [[UInt8]] = [
        "div", "p", "br", "span", "b", "strong", "i", "em", "u", "s", "a", "ul", "ol", "li", "blockquote", "pre", "code",
        "h1", "h2", "h3", "h4", "h5", "h6", "table", "thead", "tbody", "tr", "td", "th", "hr",
    ].map { Array($0.utf8) }

    var name: [UInt8] { Tag.names[Int(rawValue)] }

    /// A set of tags as bits (no allocation).
    struct Mask {
        var bits: UInt32
        init(_ tags: [Tag]) { bits = tags.reduce(0) { $0 | 1 << UInt32($1.rawValue) } }
        func contains(_ tag: Tag) -> Bool { bits & (1 << UInt32(tag.rawValue)) != 0 }
        static let paragraphBoundaries = Mask([.div, .li, .td, .th, .blockquote, .table, .ul, .ol])
    }

    var isBlock: Bool {
        switch self {
        case .div, .p, .br, .ul, .ol, .li, .blockquote, .pre, .h1, .h2, .h3, .h4, .h5, .h6, .table, .thead, .tbody, .tr,
             .td, .th, .hr: true
        default: false
        }
    }

    /// Opening one of these closes an open `p` (HTML's implied end tag).
    var closesParagraph: Bool {
        switch self {
        case .div, .p, .ul, .ol, .blockquote, .pre, .h1, .h2, .h3, .h4, .h5, .h6, .table, .hr: true
        default: false
        }
    }
}

/// What an input tag name does.
private enum TagAction {
    case emit(Tag)
    /// Drop the tag, keep its content.
    case unwrap
    /// Drop the tag (void element) .
    case void
    /// Drop the element and its raw-text content (script, style, …).
    case rawText
    /// Drop the element and everything inside it (svg, math, select, …).
    case dropContent
}

/// A tag name packed into an integer (6 bits per character, at most 10 characters; 0 = longer
/// or unknown), so looking a tag up allocates nothing.
private enum TagKey {
    static func code(_ byte: UInt8) -> UInt64 {
        switch byte | 0x20 {
        case 0x61...0x7A: UInt64((byte | 0x20) - 0x60)          // a–z: 1…26
        default:
            switch byte {
            case 0x30...0x39: UInt64(byte - 0x30 + 27)          // 0–9: 27…36
            case UInt8(ascii: "-"): 37
            case UInt8(ascii: ":"): 38
            default: 39
            }
        }
    }

    static func make<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        guard !bytes.isEmpty, bytes.count <= 10 else { return 0 }
        var key: UInt64 = 0
        for byte in bytes { key = key << 6 | code(byte) }
        return key
    }

    static let a = make("a".utf8)
    static let href = make("href".utf8)
    static let plaintext = make("plaintext".utf8)
}

private let tagActions: [UInt64: TagAction] = {
    var map: [UInt64: TagAction] = [:]
    for (index, name) in Tag.names.enumerated() {
        if let tag = Tag(rawValue: UInt8(index)) { map[TagKey.make(name)] = .emit(tag) }
    }
    let aliases: [String: Tag] = [
        "strike": .s, "del": .s, "ins": .u, "tt": .code, "kbd": .code, "samp": .code, "var": .code, "tfoot": .tbody,
        "center": .div, "section": .div, "article": .div, "header": .div, "footer": .div, "main": .div, "nav": .div,
        "aside": .div, "address": .div, "figure": .div, "figcaption": .div, "details": .div, "summary": .div,
        "dl": .div, "dd": .div, "dt": .div, "fieldset": .div, "legend": .div, "caption": .div, "hgroup": .div,
        "dir": .ul, "menu": .ul, "listing": .pre,
    ]
    for (name, tag) in aliases { map[TagKey.make(name.utf8)] = .emit(tag) }
    for name in ["img", "input", "meta", "link", "base", "col", "area", "source", "track", "param", "embed", "wbr",
                 "keygen", "basefont", "bgsound", "image", "frame", "isindex"] {
        map[TagKey.make(name.utf8)] = .void
    }
    for name in ["script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes", "noscript", "plaintext"] {
        map[TagKey.make(name.utf8)] = .rawText
    }
    for name in ["svg", "math", "object", "applet", "template", "select", "option", "optgroup", "datalist", "button",
                 "video", "audio", "canvas", "map", "frameset", "colgroup", "head"] {
        map[TagKey.make(name.utf8)] = .dropContent
    }
    return map
}()

// MARK: - Bytes

private extension UInt8 {
    static let lt = UInt8(ascii: "<")
    static let gt = UInt8(ascii: ">")
    static let amp = UInt8(ascii: "&")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let slash = UInt8(ascii: "/")
    static let equals = UInt8(ascii: "=")
    static let bang = UInt8(ascii: "!")
    static let question = UInt8(ascii: "?")
    static let semicolon = UInt8(ascii: ";")
    static let hash = UInt8(ascii: "#")
    static let dash = UInt8(ascii: "-")
    static let space = UInt8(ascii: " ")

    var isHTMLSpace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D || self == 0x0C }
    var isASCIILetter: Bool { (self | 0x20) >= 0x61 && (self | 0x20) <= 0x7A }
    var isDigit: Bool { self >= 0x30 && self <= 0x39 }
    var lowercasedASCII: UInt8 { self >= 0x41 && self <= 0x5A ? self | 0x20 : self }
    var isTagNameByte: Bool { isASCIILetter || isDigit || self == UInt8(ascii: "-") || self == UInt8(ascii: ":") || self == UInt8(ascii: "_") }
}

private func appendEscaped(_ scalar: UInt32, to output: inout [UInt8]) {
    switch scalar {
    case 0x3C: output.append(contentsOf: [0x26, 0x6C, 0x74, 0x3B])           // &lt;
    case 0x3E: output.append(contentsOf: [0x26, 0x67, 0x74, 0x3B])           // &gt;
    case 0x26: output.append(contentsOf: [0x26, 0x61, 0x6D, 0x70, 0x3B])     // &amp;
    case 0x22: output.append(contentsOf: [0x26, 0x71, 0x75, 0x6F, 0x74, 0x3B]) // &quot;
    case 0x09, 0x0A, 0x0D: output.append(UInt8(scalar))
    case 0..<0x20, 0xFFFE, 0xFFFF, 0xD800...0xDFFF: break                    // not XML characters
    case 0x20..<0x80: output.append(UInt8(scalar))
    default:
        guard scalar <= 0x10FFFF else { output.append(contentsOf: [0xEF, 0xBF, 0xBD]); return }
        if scalar < 0x800 {
            output.append(UInt8(0xC0 | (scalar >> 6)))
            output.append(UInt8(0x80 | (scalar & 0x3F)))
        } else if scalar < 0x10000 {
            output.append(UInt8(0xE0 | (scalar >> 12)))
            output.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (scalar & 0x3F)))
        } else {
            output.append(UInt8(0xF0 | (scalar >> 18)))
            output.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            output.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }
}

// MARK: - Sanitizer

private struct Sanitizer {
    let input: UnsafeBufferPointer<UInt8>
    var output: [UInt8] = []
    var stack: [Tag] = []
    var pendingSpace = false
    var preDepth = 0
    var lastWasBlock = true

    static let maximumDepth = 64

    init(input: UnsafeBufferPointer<UInt8>) {
        self.input = input
        output.reserveCapacity(input.count + 32)
    }

    mutating func run() -> String {
        output.append(contentsOf: Array("<div>".utf8))
        let count = input.count
        var index = 0
        // Literals instead of the `UInt8` constants: this loop runs once per byte, and Debug
        // builds call an accessor for every use of a static.
        while index < count {
            let byte = input[index]
            if byte == 0x3C {
                index = handleMarkup(at: index)
            } else if byte == 0x26 {
                let (scalar, next) = Entities.decode(input, at: index)
                appendText(scalar)
                index = next
            } else if byte < 0x80 {
                if byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D || byte == 0x0C, preDepth == 0 {
                    pendingSpace = true
                } else {
                    if pendingSpace { flushSpace() }
                    if byte >= 0x20, byte != 0x3E, byte != 0x22 {
                        output.append(byte)
                    } else {
                        appendEscaped(UInt32(byte), to: &output)
                    }
                    lastWasBlock = false
                }
                index += 1
            } else {
                // Multi-byte UTF-8 from a Swift string is valid; copy the sequence, minus the
                // non-characters U+FFFE / U+FFFF (EF BF BE / EF BF BF).
                flushSpace()
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                let end = min(index + length, count)
                if length == 3, end - index == 3, byte == 0xEF, input[index + 1] == 0xBF, input[index + 2] >= 0xBE {
                    // dropped
                } else {
                    for position in index..<end { output.append(input[position]) }
                }
                lastWasBlock = false
                index = end
            }
        }
        while let tag = stack.popLast() { appendClose(tag) }
        output.append(contentsOf: Array("</div>".utf8))
        return String(decoding: output, as: UTF8.self)
    }

    mutating func flushSpace() {
        if pendingSpace {
            if !lastWasBlock { output.append(.space) }
            pendingSpace = false
        }
    }

    mutating func appendText(_ scalar: UInt32) {
        if scalar == 0x20 || scalar == 0x09 || scalar == 0x0A || scalar == 0x0D, preDepth == 0 {
            pendingSpace = true
            return
        }
        flushSpace()
        appendEscaped(scalar, to: &output)
        lastWasBlock = false
    }

    // MARK: Markup

    /// Handles what starts with "<" at `index`; returns the index after it.
    mutating func handleMarkup(at index: Int) -> Int {
        let count = input.count
        guard index + 1 < count else {
            appendText(0x3C)
            return index + 1
        }
        let next = input[index + 1]
        if next == .bang {
            if index + 3 < count, input[index + 2] == .dash, input[index + 3] == .dash {
                return skip(past: [.dash, .dash, .gt], from: index + 4)
            }
            if matches(Array("[CDATA[".utf8), at: index + 2) {
                return skip(past: Array("]]>".utf8), from: index + 9)
            }
            return skip(past: [.gt], from: index + 2)
        }
        if next == .question {
            return skip(past: [.gt], from: index + 2)
        }
        if next == .slash {
            var position = index + 2
            let nameStart = position
            while position < count, input[position].isTagNameByte { position += 1 }
            if position == nameStart {
                // "</ " or "</>": not a tag in HTML; drop up to ">".
                return skip(past: [.gt], from: position)
            }
            let end = skipTagRemainder(from: position)
            handleClose(key(nameStart, position))
            return end
        }
        if next.isASCIILetter {
            var position = index + 1
            let nameStart = position
            while position < count, input[position].isTagNameByte { position += 1 }
            let tagKey = key(nameStart, position)
            let (end, href) = parseAttributes(from: position, wantHref: tagKey == TagKey.a)
            return handleOpen(tagKey, name: nameStart..<position, href: href, end: end)
        }
        appendText(0x3C)
        return index + 1
    }

    func matches(_ pattern: [UInt8], at index: Int) -> Bool {
        guard index + pattern.count <= input.count else { return false }
        for offset in 0..<pattern.count where input[index + offset].lowercasedASCII != pattern[offset].lowercasedASCII {
            return false
        }
        return true
    }

    func skip(past pattern: [UInt8], from start: Int) -> Int {
        let count = input.count
        var index = start
        while index + pattern.count <= count {
            if input[index] == pattern[0], matches(pattern, at: index) { return index + pattern.count }
            index += 1
        }
        return count
    }

    func key(_ start: Int, _ end: Int) -> UInt64 {
        guard end > start, end - start <= 10 else { return 0 }
        var key: UInt64 = 0
        var position = start
        while position < end {
            key = key << 6 | TagKey.code(input[position])
            position += 1
        }
        return key
    }

    func lowercasedName(_ start: Int, _ end: Int) -> [UInt8] {
        var name: [UInt8] = []
        name.reserveCapacity(end - start)
        for position in start..<end { name.append(input[position].lowercasedASCII) }
        return name
    }

    /// Skips attributes (respecting quotes) to just after ">".
    func skipTagRemainder(from start: Int) -> Int {
        let count = input.count
        var index = start
        var quote: UInt8 = 0
        while index < count {
            let byte = input[index]
            if quote != 0 {
                if byte == quote { quote = 0 }
            } else if byte == .quote || byte == .apostrophe {
                quote = byte
            } else if byte == .gt {
                return index + 1
            }
            index += 1
        }
        return count
    }

    /// Parses attributes up to ">" and returns the index after it and the `href` value (raw).
    func parseAttributes(from start: Int, wantHref: Bool) -> (Int, [UInt8]?) {
        guard wantHref else { return (skipTagRemainder(from: start), nil) }
        let count = input.count
        var index = start
        var href: [UInt8]?
        while index < count {
            while index < count, input[index].isHTMLSpace || input[index] == .slash { index += 1 }
            guard index < count else { break }
            if input[index] == .gt { return (index + 1, href) }
            let nameStart = index
            while index < count, !input[index].isHTMLSpace, input[index] != .equals, input[index] != .gt, input[index] != .slash {
                index += 1
            }
            let isHref = key(nameStart, index) == TagKey.href
            while index < count, input[index].isHTMLSpace { index += 1 }
            var value: Range<Int> = index..<index
            if index < count, input[index] == .equals {
                index += 1
                while index < count, input[index].isHTMLSpace { index += 1 }
                if index < count, input[index] == .quote || input[index] == .apostrophe {
                    let quote = input[index]
                    index += 1
                    let valueStart = index
                    while index < count, input[index] != quote { index += 1 }
                    value = valueStart..<min(index, count)
                    if index < count { index += 1 }
                } else {
                    let valueStart = index
                    while index < count, !input[index].isHTMLSpace, input[index] != .gt { index += 1 }
                    value = valueStart..<index
                }
            }
            if isHref, href == nil { href = Array(input[value]) }
        }
        return (count, href)
    }

    // MARK: Elements

    mutating func handleOpen(_ key: UInt64, name: Range<Int>, href: [UInt8]?, end: Int) -> Int {
        let selfClosing = end >= 2 && input[end - 2] == .slash
        switch tagActions[key] ?? .unwrap {
        case .unwrap, .void:
            return end
        case .rawText:
            if key == TagKey.plaintext { return input.count }
            return skipRawText(lowercasedName(name.lowerBound, name.upperBound), from: end)
        case .dropContent:
            if selfClosing { return end }
            return skipElement(lowercasedName(name.lowerBound, name.upperBound), from: end)
        case .emit(let tag):
            emitOpen(tag, href: href)
            return end
        }
    }

    mutating func emitOpen(_ tag: Tag, href: [UInt8]?) {
        if tag == .br || tag == .hr {
            if tag == .hr { closeParagraph() }
            pendingSpace = false
            output.append(.lt)
            output.append(contentsOf: tag.name)
            output.append(contentsOf: [.slash, .gt])
            lastWasBlock = true
            return
        }
        if tag.closesParagraph { closeParagraph() }
        switch tag {
        case .li: closeOpen(.li, within: Tag.Mask([.ul, .ol]))
        case .tr: closeOpen(.tr, within: Tag.Mask([.table, .thead, .tbody]))
        case .td, .th:
            closeOpen(.td, within: Tag.Mask([.tr, .table]))
            closeOpen(.th, within: Tag.Mask([.tr, .table]))
        case .thead, .tbody:
            closeOpen(.thead, within: Tag.Mask([.table]))
            closeOpen(.tbody, within: Tag.Mask([.table]))
        default: break
        }
        guard stack.count < Self.maximumDepth else { return }
        var safeHref: [UInt8]?
        if tag == .a {
            guard let href, let cleaned = Self.safeURL(href) else { return }
            safeHref = cleaned
        }
        if tag.isBlock { pendingSpace = false } else { flushSpace() }
        output.append(.lt)
        output.append(contentsOf: tag.name)
        if let safeHref {
            output.append(contentsOf: Array(" href=\"".utf8))
            for byte in safeHref { appendEscaped(UInt32(byte), to: &output) }
            output.append(.quote)
        }
        output.append(.gt)
        stack.append(tag)
        if tag == .pre { preDepth += 1 }
        if tag.isBlock { lastWasBlock = true }
    }

    /// Closes an open `tag` that sits above the nearest of `boundaries` (implied end tags).
    mutating func closeOpen(_ tag: Tag, within boundaries: Tag.Mask) {
        var position = stack.count - 1
        while position >= 0 {
            let open = stack[position]
            if open == tag { break }
            if boundaries.contains(open) { return }
            position -= 1
        }
        guard position >= 0 else { return }
        while stack.count > position {
            if let top = stack.popLast() { appendClose(top) }
        }
    }

    mutating func closeParagraph() {
        closeOpen(.p, within: Tag.Mask.paragraphBoundaries)
    }

    mutating func handleClose(_ key: UInt64) {
        guard case .emit(let tag)? = tagActions[key] else { return }
        if tag == .br {
            emitOpen(.br, href: nil)
            return
        }
        guard let position = stack.lastIndex(of: tag) else { return }
        while stack.count > position {
            if let top = stack.popLast() { appendClose(top) }
        }
    }

    mutating func appendClose(_ tag: Tag) {
        if tag.isBlock { pendingSpace = false }
        output.append(contentsOf: [.lt, .slash])
        output.append(contentsOf: tag.name)
        output.append(.gt)
        if tag == .pre { preDepth = max(0, preDepth - 1) }
        if tag.isBlock { lastWasBlock = true }
    }

    /// Skips the content of a raw-text element to after its end tag.
    func skipRawText(_ name: [UInt8], from start: Int) -> Int {
        let count = input.count
        var index = start
        while index + 1 < count {
            if input[index] == .lt, input[index + 1] == .slash, matches(name, at: index + 2) {
                let after = index + 2 + name.count
                if after >= count || !input[after].isTagNameByte { return skipTagRemainder(from: after) }
            }
            index += 1
        }
        return count
    }

    /// Skips an element with all its content, counting nested elements of the same name. An
    /// unclosed one drops the rest of the document (fail closed).
    func skipElement(_ name: [UInt8], from start: Int) -> Int {
        let count = input.count
        var depth = 1
        var index = start
        while index + 1 < count {
            if input[index] == .lt {
                let closing = input[index + 1] == .slash
                let nameAt = index + (closing ? 2 : 1)
                if matches(name, at: nameAt) {
                    let after = nameAt + name.count
                    if after >= count || !input[after].isTagNameByte {
                        let end = skipTagRemainder(from: after)
                        if closing {
                            depth -= 1
                            if depth == 0 { return end }
                        } else if !(end >= 2 && input[end - 2] == .slash) {
                            depth += 1
                        }
                        index = end
                        continue
                    }
                }
            }
            index += 1
        }
        return count
    }

    /// The URL when it is http, https or mailto: entities decoded, whitespace and control
    /// characters removed (browsers ignore them inside schemes), at most 2,048 bytes.
    static func safeURL(_ raw: [UInt8]) -> [UInt8]? {
        var decoded: [UInt8] = []
        raw.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                if buffer[index] == .amp {
                    let (scalar, next) = Entities.decode(buffer, at: index)
                    appendEscapedRaw(scalar, to: &decoded)
                    index = next
                } else {
                    decoded.append(buffer[index])
                    index += 1
                }
            }
        }
        let cleaned = decoded.filter { $0 > 0x20 && $0 != 0x7F }
        guard !cleaned.isEmpty, cleaned.count <= 2_048 else { return nil }
        let lower = cleaned.prefix(8).map(\.lowercasedASCII)
        let allowed = [Array("https://".utf8), Array("http://".utf8), Array("mailto:".utf8)]
        guard allowed.contains(where: { lower.starts(with: $0) }) else { return nil }
        return cleaned
    }

    /// UTF-8 of a scalar without XML escaping (for URL checks).
    private static func appendEscapedRaw(_ scalar: UInt32, to output: inout [UInt8]) {
        guard let unicode = Unicode.Scalar(scalar) else { return }
        output.append(contentsOf: Array(String(Character(unicode)).utf8))
    }
}

// MARK: - Entities

enum Entities {
    /// Decodes the character reference at `index` ("&amp;", "&#228;", "&#xE4;"); an unknown or
    /// malformed one is a literal "&". Returns the scalar and the index after the reference.
    static func decode(_ input: UnsafeBufferPointer<UInt8>, at index: Int) -> (UInt32, Int) {
        let count = input.count
        var position = index + 1
        guard position < count else { return (0x26, index + 1) }
        if input[position] == .hash {
            position += 1
            var hex = false
            if position < count, input[position] | 0x20 == UInt8(ascii: "x") { hex = true; position += 1 }
            var value: UInt32 = 0
            let digitsStart = position
            while position < count, position - digitsStart < 8 {
                let byte = input[position]
                let digit: UInt32
                if byte.isDigit {
                    digit = UInt32(byte - 0x30)
                } else if hex, (byte | 0x20) >= 0x61, (byte | 0x20) <= 0x66 {
                    digit = UInt32((byte | 0x20) - 0x61 + 10)
                } else {
                    break
                }
                value = value * (hex ? 16 : 10) + digit
                position += 1
            }
            guard position > digitsStart else { return (0x26, index + 1) }
            if position < count, input[position] == .semicolon { position += 1 }
            if value == 0 || value > 0x10FFFF || (0xD800...0xDFFF).contains(value) { value = 0xFFFD }
            // Windows-1252 numeric references (&#150; etc.) as browsers read them.
            if (0x80...0x9F).contains(value), let mapped = windows1252[value] { value = mapped }
            return (value, position)
        }
        let nameStart = position
        while position < count, position - nameStart < 32, input[position].isASCIILetter || input[position].isDigit {
            position += 1
        }
        guard position > nameStart, position < count, input[position] == .semicolon else { return (0x26, index + 1) }
        guard let key = namedKey(UnsafeBufferPointer(rebasing: input[nameStart..<position])), let scalar = namedByKey[key] else {
            return (0x26, index + 1)
        }
        return (scalar, position + 1)
    }

    /// An entity name packed into an integer (7 bits per ASCII character, case kept, at most 9).
    static func namedKey<C: Collection>(_ bytes: C) -> UInt64? where C.Element == UInt8 {
        guard !bytes.isEmpty, bytes.count <= 9 else { return nil }
        var key: UInt64 = 0
        for byte in bytes { key = key << 7 | UInt64(byte & 0x7F) }
        return key
    }

    static let namedByKey: [UInt64: UInt32] = {
        var map: [UInt64: UInt32] = [:]
        for (name, scalar) in named { if let key = namedKey(Array(name.utf8)) { map[key] = scalar } }
        return map
    }()

    static let windows1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6,
        0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C,
        0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A,
        0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]

    static let named: [String: UInt32] = [
        "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27, "nbsp": 0xA0, "shy": 0xAD,
        "auml": 0xE4, "ouml": 0xF6, "uuml": 0xFC, "Auml": 0xC4, "Ouml": 0xD6, "Uuml": 0xDC, "szlig": 0xDF,
        "aacute": 0xE1, "eacute": 0xE9, "iacute": 0xED, "oacute": 0xF3, "uacute": 0xFA, "Eacute": 0xC9,
        "agrave": 0xE0, "egrave": 0xE8, "ugrave": 0xF9, "acirc": 0xE2, "ecirc": 0xEA, "ocirc": 0xF4, "ccedil": 0xE7,
        "ntilde": 0xF1, "euml": 0xEB, "iuml": 0xEF, "oslash": 0xF8, "aring": 0xE5, "aelig": 0xE6,
        "euro": 0x20AC, "pound": 0xA3, "yen": 0xA5, "cent": 0xA2, "copy": 0xA9, "reg": 0xAE, "trade": 0x2122,
        "deg": 0xB0, "plusmn": 0xB1, "times": 0xD7, "divide": 0xF7, "micro": 0xB5, "para": 0xB6, "sect": 0xA7,
        "middot": 0xB7, "bull": 0x2022, "hellip": 0x2026, "ndash": 0x2013, "mdash": 0x2014, "minus": 0x2212,
        "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A, "ldquo": 0x201C, "rdquo": 0x201D, "bdquo": 0x201E,
        "laquo": 0xAB, "raquo": 0xBB, "lsaquo": 0x2039, "rsaquo": 0x203A, "rarr": 0x2192, "larr": 0x2190,
        "uarr": 0x2191, "darr": 0x2193, "harr": 0x2194, "rArr": 0x21D2, "zwnj": 0x200C, "zwj": 0x200D,
        "ensp": 0x2002, "emsp": 0x2003, "thinsp": 0x2009, "iexcl": 0xA1, "iquest": 0xBF, "ordf": 0xAA, "ordm": 0xBA,
        "sup1": 0xB9, "sup2": 0xB2, "sup3": 0xB3, "frac12": 0xBD, "frac14": 0xBC, "frac34": 0xBE, "dagger": 0x2020,
        "check": 0x2713, "hearts": 0x2665,
    ]
}

// MARK: - Text extraction

private struct TextExtractor {
    let input: UnsafeBufferPointer<UInt8>
    var output: [UInt8] = []
    var quoteDepth = 0
    var preDepth = 0
    var atLineStart = true
    var cellIndex: [Int] = []
    var listDepth = 0

    init(input: UnsafeBufferPointer<UInt8>) {
        self.input = input
        output.reserveCapacity(input.count)
    }

    mutating func run() -> String {
        let count = input.count
        var index = 0
        while index < count {
            let byte = input[index]
            if byte == .lt {
                index = handleTag(at: index)
            } else if byte == .amp {
                let (scalar, next) = Entities.decode(input, at: index)
                appendScalar(scalar)
                index = next
            } else {
                if byte == 0x0A, preDepth > 0 {
                    lineBreak(force: true)
                } else if byte.isHTMLSpace {
                    if preDepth > 0 {
                        if byte != 0x0D { appendByte(byte == 0x0C ? .space : byte) }
                    } else if !atLineStart {
                        appendByte(.space)
                    }
                } else {
                    appendByte(byte)
                }
                index += 1
            }
        }
        return finish()
    }

    mutating func appendByte(_ byte: UInt8) {
        if atLineStart {
            if byte == .space || byte == 0x09, preDepth == 0 { return }
            for _ in 0..<quoteDepth { output.append(contentsOf: [.gt, .space]) }
            atLineStart = false
        }
        output.append(byte)
    }

    mutating func appendScalar(_ scalar: UInt32) {
        if scalar == 0x20 || scalar == 0xA0 {
            if !atLineStart { appendByte(.space) }
            return
        }
        guard let unicode = Unicode.Scalar(scalar) else { return }
        for byte in String(Character(unicode)).utf8 { appendByte(byte) }
    }

    mutating func lineBreak(force: Bool = false) {
        if !force, atLineStart { return }
        // Trim spaces at the end of the line.
        while output.last == .space { output.removeLast() }
        output.append(0x0A)
        atLineStart = true
    }

    mutating func paragraphBreak() {
        lineBreak()
        while output.last == .space { output.removeLast() }
        if output.count >= 2, output[output.count - 1] == 0x0A, output[output.count - 2] == 0x0A { return }
        if output.isEmpty { return }
        output.append(0x0A)
        atLineStart = true
    }

    mutating func handleTag(at index: Int) -> Int {
        let count = input.count
        var position = index + 1
        let closing = position < count && input[position] == .slash
        if closing { position += 1 }
        let nameStart = position
        while position < count, input[position].isTagNameByte { position += 1 }
        var name = String(decoding: UnsafeBufferPointer(rebasing: input[nameStart..<position]), as: UTF8.self)
        name = name.lowercased()
        while position < count, input[position] != .gt { position += 1 }
        let end = min(position + 1, count)
        switch (name, closing) {
        case ("br", _): lineBreak(force: true)
        case ("hr", _): paragraphBreak()
        case ("p", _), ("h1", _), ("h2", _), ("h3", _), ("h4", _), ("h5", _), ("h6", _), ("table", _):
            paragraphBreak()
        case ("ul", false), ("ol", false):
            listDepth += 1
            lineBreak()
        case ("ul", true), ("ol", true):
            listDepth = max(0, listDepth - 1)
            if listDepth == 0 { paragraphBreak() } else { lineBreak() }
        case ("li", false):
            lineBreak()
            for byte in "• ".utf8 { appendByte(byte) }
        case ("li", true), ("div", _), ("thead", _), ("tbody", _):
            lineBreak()
        case ("tr", false):
            lineBreak()
            cellIndex.append(0)
        case ("tr", true):
            lineBreak()
            _ = cellIndex.popLast()
        case ("td", false), ("th", false):
            if let last = cellIndex.indices.last {
                if cellIndex[last] > 0 { appendByte(0x09) }
                cellIndex[last] += 1
            }
        case ("blockquote", false):
            paragraphBreak()
            quoteDepth += 1
        case ("blockquote", true):
            lineBreak()
            quoteDepth = max(0, quoteDepth - 1)
            paragraphBreak()
        case ("pre", false):
            paragraphBreak()
            preDepth += 1
        case ("pre", true):
            preDepth = max(0, preDepth - 1)
            paragraphBreak()
        default:
            break
        }
        return end
    }

    mutating func finish() -> String {
        var text = String(decoding: output, as: UTF8.self)
        // Collapse runs of blank lines and trim.
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
