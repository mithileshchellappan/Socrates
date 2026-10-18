import Deadlines
import Foundation
import StudyCore

/// ma (docs/plan-agent.md §4): what of a finished recording goes to the batched triage: the lines
/// that may change a session (another room, time or day, a cancellation, an extra or make-up
/// session), an exam date or a course rule (admission, bonus, attendance), each with ±2 lines,
/// merged. Never the whole transcript. The transcript pipeline records a `transcript` event only
/// when there is such a line; triage sends these windows as `<line id t>` elements and verifies
/// each quote against them (`TranscriptQuote.locate`, the first word's time).
public enum TranscriptCues {
    /// The recording's lines as triage numbers them ("l1", "l2", … over the non-empty lines in
    /// time order, as the transcript extraction does).
    public static func lines(_ segments: [TranscriptSegment]) -> [TranscriptQuote.Line] {
        segments.sorted { $0.startTime < $1.startTime }.enumerated().compactMap { index, segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptQuote.Line(id: "l\(index + 1)", text: text, start: segment.startTime, words: segment.words ?? [])
        }
    }

    /// The windows around session, exam and rule cues; empty when the class said nothing of the kind.
    public static func windows(_ lines: [TranscriptQuote.Line], radius: Int = 2, maximumLines: Int = 120) -> [ClosedRange<Int>] {
        var windows: [ClosedRange<Int>] = []
        var count = 0
        for (index, line) in lines.enumerated() where isCue(line.text) {
            let window = max(0, index - radius)...min(lines.count - 1, index + radius)
            if let last = windows.last, window.lowerBound <= last.upperBound + 1 {
                let merged = last.lowerBound...max(last.upperBound, window.upperBound)
                count += merged.count - last.count
                windows[windows.count - 1] = merged
            } else {
                guard count + window.count <= maximumLines else { break }
                windows.append(window)
                count += window.count
            }
        }
        return windows
    }

    /// The windows as triage reads them: `<line id="l17" t="57:18">text</line>`, escaped, at most
    /// `characters` characters.
    public static func text(_ lines: [TranscriptQuote.Line], windows: [ClosedRange<Int>], characters: Int = 6_000) -> String {
        var output: [String] = []
        var used = 0
        for window in windows {
            for index in window {
                let line = lines[index]
                let element = "<line id=\"\(line.id)\" t=\"\(clock(line.start))\">\(AgentXML.escape(line.text))</line>"
                guard used + element.count <= characters else { return output.joined(separator: "\n") }
                output.append(element)
                used += element.count + 1
            }
            output.append("<gap/>")
        }
        return output.joined(separator: "\n")
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A line that may change a session, an exam date or a course rule (DE/EN).
    public static func isCue(_ text: String) -> Bool {
        let words = TextFolding.words(text)
        if !Set(words).isDisjoint(with: cueWords) { return true }
        if words.contains(where: { word in cuePrefixes.contains { word.hasPrefix($0) } }) { return true }
        let folded = " " + words.joined(separator: " ") + " "
        return cuePhrases.contains { folded.contains($0) }
    }

    static let cueWords: Set<String> = [
        "room", "raum", "hall", "horsaal", "cancelled", "canceled", "cancel", "entfallt", "entfallen", "ausfallen", "fallt",
        "moved", "move", "postponed", "postpone", "verschoben", "verlegt", "instead", "statt", "stattdessen", "extra",
        "additional", "zusatzlich", "zusatztermin", "makeup", "nachholtermin", "exam", "exams", "klausur", "prufung",
        "admission", "zulassung", "bonus", "attendance", "anwesenheit", "mandatory", "pflicht", "online", "zoom",
    ]

    static let cuePrefixes = ["klausur", "prufung", "zulassung", "verschieb", "verleg", "nachhol", "anwesenheit"]

    static let cuePhrases = [" next week ", " nachste woche ", " nachsten woche ", " naechste woche ", " no lecture ", " no class "]
}
