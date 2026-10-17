import Foundation
import StudyCore

/// One line of the review transcript (mockup 03): consecutive transcript segments joined into a
/// sentence. Whisper's segments are 3–7 s and break mid-sentence; a line is what was said in one
/// go, so it starts with its sentence and wraps to the column. Display only: the database keeps
/// its segments.
public struct TranscriptLine: Sendable, Hashable, Identifiable {
    /// The first segment's id.
    public var id: UUID
    /// In time order, never empty.
    public var segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.id = segments.first?.id ?? UUID()
        self.segments = segments
    }

    public var start: Double { segments.first?.startTime ?? 0 }
    public var end: Double { segments.map(\.endTime).max() ?? start }
    public var segmentIDs: [UUID] { segments.map(\.id) }
    /// The segments' texts, one space apart.
    public var text: String { TranscriptLines.joined(segments.map(\.text)) }
    /// The first segment's language (lines rarely switch inside a sentence).
    public var language: String { segments.first?.lang ?? "" }
}

/// Joins a slide visit's segments into sentence lines.
public enum TranscriptLines {
    /// A pause longer than this ends a line.
    public static let maximumGap: Double = 1.5
    /// A line that has reached this length (seconds or characters) ends, sentence or not.
    public static let maximumDuration: Double = 25
    public static let maximumLength = 280

    /// The lines of `segments` (one section's, in any order). A line ends where its text ends a
    /// sentence (. ? !), before a pause over `maximumGap`, or once it is `maximumDuration` long or
    /// `maximumLength` characters. Sections are joined separately, so a line never crosses a
    /// slide.
    public static func lines(_ segments: [TranscriptSegment]) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var current: [TranscriptSegment] = []
        func close() {
            if !current.isEmpty { lines.append(TranscriptLine(segments: current)) }
            current = []
        }
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            if let last = current.last, segment.startTime - last.endTime > maximumGap {
                close()
            }
            current.append(segment)
            let start = current.first?.startTime ?? segment.startTime
            let length = joined(current.map(\.text)).count
            if endsSentence(segment.text) || segment.endTime - start >= maximumDuration || length >= maximumLength {
                close()
            }
        }
        close()
        return lines
    }

    /// Each segment's line id, for finding the playhead's line.
    public static func lineIDs(_ lines: [TranscriptLine]) -> [UUID: UUID] {
        var ids: [UUID: UUID] = [:]
        for line in lines {
            for segment in line.segments { ids[segment.id] = line.id }
        }
        return ids
    }

    /// Ends with . ? or ! (after closing quotes or brackets); an ellipsis trails off instead.
    static func endsSentence(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, "\"'”’»)]".contains(last) { trimmed.removeLast() }
        guard let last = trimmed.last else { return false }
        if trimmed.hasSuffix("...") || last == "…" { return false }
        return last == "." || last == "?" || last == "!"
    }

    static func joined(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
