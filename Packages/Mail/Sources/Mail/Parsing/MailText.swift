import Foundation
import NaturalLanguage

// Plain-text helpers: format=flowed, line endings, the list snippet and the language.

enum MailText {
    /// "\r\n" and "\r" → "\n". (Checked on UTF-8: in Swift "\r\n" is one Character, so
    /// `contains("\r")` would miss it.)
    static func normalizeLineEndings(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// RFC 3676 format=flowed: lines ending in a space continue on the next line (same quote
    /// depth); space-stuffing removed; "-- " stays a hard line. `delSp` removes the soft space.
    static func unflow(_ text: String, delSp: Bool) -> String {
        var output: [String] = []
        var paragraph = ""
        var paragraphDepth = -1
        func flush() {
            guard paragraphDepth >= 0 else { return }
            let prefix = paragraphDepth > 0 ? String(repeating: ">", count: paragraphDepth) + " " : ""
            output.append(prefix + paragraph)
            paragraph = ""
            paragraphDepth = -1
        }
        for rawLine in normalizeLineEndings(text).components(separatedBy: "\n") {
            var depth = 0
            var line = Substring(rawLine)
            while line.first == ">" {
                depth += 1
                line = line.dropFirst()
            }
            if line.first == " " { line = line.dropFirst() }   // space-stuffing (or the space after ">")
            let isSignature = line == "-- "
            let soft = !isSignature && line.hasSuffix(" ")
            if paragraphDepth >= 0, depth != paragraphDepth { flush() }
            var content = String(line)
            if soft, delSp { content.removeLast() }
            paragraph += content
            paragraphDepth = depth
            if !soft { flush() }
        }
        flush()
        return output.joined(separator: "\n")
    }

    /// Lines of the reply itself: quoted lines, the attribution line before a quote, everything
    /// from the signature separator (or a forwarded/original-message marker) on are left out.
    static func ownLines(_ text: String) -> [String] {
        var result: [String] = []
        let lines = normalizeLineEndings(text).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line == "-- " || trimmed == "--" || isMarker(trimmed) { break }
            if trimmed.hasPrefix(">") { continue }
            if isAttribution(trimmed), lines[(index + 1)...].prefix(3).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") || $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                continue
            }
            result.append(line)
        }
        return result
    }

    private static func isMarker(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("-----original message") || lower.hasPrefix("-----ursprüngliche nachricht")
            || lower.hasPrefix("---------- forwarded message") || lower.hasPrefix("---------- weitergeleitete nachricht")
            || lower == "sent from my iphone" || lower == "von meinem iphone gesendet"
    }

    private static func isAttribution(_ line: String) -> Bool {
        guard line.hasSuffix(":") else { return false }
        let lower = line.lowercased()
        return (lower.hasPrefix("on ") && lower.contains("wrote")) || (lower.hasPrefix("am ") && lower.contains("schrieb"))
    }

    /// About 200 characters for the message list: the reply's own text, whitespace collapsed,
    /// cut at a word boundary. Falls back to all text when nothing of its own is left.
    static func snippet(_ text: String, limit: Int = 200) -> String {
        var source = ownLines(text).joined(separator: " ")
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = normalizeLineEndings(text)
                .components(separatedBy: "\n")
                .map { $0.drop(while: { $0 == ">" || $0 == " " }) }
                .joined(separator: " ")
        }
        let collapsed = source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space])
        }
        return String(cut)
    }

    /// "de", "en" or "" (too little text to tell), from the subject and the reply's own text.
    static func language(subject: String, body: String) -> String {
        let own = ownLines(body).joined(separator: " ")
        let sample = String((subject + "\n" + own).prefix(2_000))
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 12 else { return "" }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.german, .english]
        recognizer.processString(sample)
        switch recognizer.dominantLanguage {
        case .german?: return "de"
        case .english?: return "en"
        default: return ""
        }
    }
}
