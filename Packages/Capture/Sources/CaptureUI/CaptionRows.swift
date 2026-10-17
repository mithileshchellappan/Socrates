import Capture
import Foundation

/// A row of the live captions: one or more recognizer lines that read as one utterance, with
/// the words still settling at its end.
struct CaptionRow: Identifiable, Hashable {
    /// The first line's id (the volatile line's -1 while a row has nothing settled yet).
    var id: Int
    /// Seconds on the recording clock where the row starts.
    var start: TimeInterval
    var settled: [CaptionTranscript.Run]
    var settling: [CaptionTranscript.Run]

    var text: String { (settled + settling).map(\.text).joined() }
}

extension CaptionTranscript {
    /// A line that does not end a sentence continues on the same row with the next one, up to
    /// `maxSpan` seconds and `maxLength` characters, so the line still settling reads as the
    /// tail of the sentence it finishes, and stays on that row once it is final.
    func rows(limit: Int = 3, maxSpan: TimeInterval = 15, maxLength: Int = 160) -> [CaptionRow] {
        var rows: [CaptionRow] = []
        for line in allLines {
            if let last = rows.last,
               !Self.endsSentence(last.text),
               line.start - last.start < maxSpan,
               last.text.count + line.text.count < maxLength {
                let runs = Self.joined(after: last.text, line.runs)
                if line.isFinal {
                    rows[rows.count - 1].settled += runs
                } else {
                    rows[rows.count - 1].settling += runs
                }
            } else {
                rows.append(CaptionRow(
                    id: line.id, start: line.start,
                    settled: line.isFinal ? line.runs : [],
                    settling: line.isFinal ? [] : line.runs
                ))
            }
        }
        return Array(rows.suffix(limit))
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace && !"\"'”’)»".contains($0) }) else { return false }
        return ".?!…。？！".contains(last)
    }

    /// `runs` with a space in front unless the row already ends with one.
    private static func joined(after text: String, _ runs: [Run]) -> [Run] {
        guard var first = runs.first, text.last.map({ !$0.isWhitespace }) ?? false,
              first.text.first.map({ !$0.isWhitespace }) ?? false else { return runs }
        first.text = " " + first.text
        return [first] + runs.dropFirst()
    }
}
