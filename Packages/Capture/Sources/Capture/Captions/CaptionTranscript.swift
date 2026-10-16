import Foundation

/// Rolling provisional captions: finalized lines plus one volatile line that is still settling.
/// Pure value type; `LiveCaptioner` feeds it speech results.
public struct CaptionTranscript: Sendable, Hashable {
    public struct Run: Sendable, Hashable {
        public var text: String
        /// Recognizer confidence below the threshold (shown dotted).
        public var isLowConfidence: Bool

        public init(text: String, isLowConfidence: Bool = false) {
            self.text = text
            self.isLowConfidence = isLowConfidence
        }
    }

    public struct Line: Sendable, Hashable, Identifiable {
        public var id: Int
        /// Seconds on the recording clock.
        public var start: TimeInterval
        public var runs: [Run]
        /// False while the recognizer may still change it.
        public var isFinal: Bool

        public var text: String { runs.map(\.text).joined() }
    }

    /// BCP 47 identifier of the recognizer's locale, e.g. "en-US".
    public var localeIdentifier: String
    public private(set) var lines: [Line] = []
    public private(set) var volatile: Line?
    public var maxLines: Int
    private var nextID = 0

    public init(localeIdentifier: String, maxLines: Int = 40) {
        self.localeIdentifier = localeIdentifier
        self.maxLines = maxLines
    }

    /// Two-letter language code for the panel header, e.g. "EN".
    public var languageCode: String {
        Locale(identifier: localeIdentifier).language.languageCode?.identifier.uppercased() ?? localeIdentifier
    }

    /// Finalized lines followed by the volatile one.
    public var allLines: [Line] {
        volatile.map { lines + [$0] } ?? lines
    }

    /// Applies one recognizer result. A final result becomes a line and clears the volatile
    /// text; a volatile result replaces the previous volatile text.
    public mutating func apply(runs: [Run], start: TimeInterval, isFinal: Bool) {
        let cleaned = Self.trimmed(runs)
        if isFinal {
            volatile = nil
            guard !cleaned.isEmpty else { return }
            lines.append(Line(id: nextID, start: start, runs: cleaned, isFinal: true))
            nextID += 1
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
        } else {
            volatile = cleaned.isEmpty ? nil : Line(id: -1, start: start, runs: cleaned, isFinal: false)
        }
    }

    private static func trimmed(_ runs: [Run]) -> [Run] {
        var result = runs.filter { !$0.text.isEmpty }
        if let first = result.first {
            result[0].text = String(first.text.drop(while: \.isWhitespace))
        }
        if let last = result.indices.last {
            result[last].text = String(result[last].text.reversed().drop(while: \.isWhitespace).reversed())
        }
        return result.filter { !$0.text.isEmpty }
    }
}
