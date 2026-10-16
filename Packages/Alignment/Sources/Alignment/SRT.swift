import Foundation

/// Minimal SubRip (.srt) reader: whisper.cpp / WhisperKit exports and imported subtitle files.
public enum SRT {
    private static let trimmed = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}"))

    /// Parses cues into transcript lines. Multi-line cue text is joined with spaces; malformed cues are skipped.
    public static func parse(_ text: String) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var timing: (start: Double, end: Double)?
        var buffer: [String] = []

        func flush() {
            if let timing, !buffer.isEmpty {
                let joined = buffer.joined(separator: " ")
                lines.append(TranscriptLine(start: timing.start, end: max(timing.start, timing.end), text: joined))
            }
            timing = nil
            buffer = []
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: Self.trimmed)
            if line.isEmpty {
                flush()
                continue
            }
            if let parsed = parseTiming(line) {
                flush()
                timing = parsed
                continue
            }
            if timing == nil {
                // Cue index lines and junk before a timing line.
                continue
            }
            buffer.append(line)
        }
        flush()
        return lines
    }

    /// "00:01:02,345 --> 00:01:04,000" (comma or dot before milliseconds; hours optional).
    static func parseTiming(_ line: String) -> (start: Double, end: Double)? {
        let parts = line.split(separator: "-->", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
              let endField = parts[1].split(separator: " ", omittingEmptySubsequences: true).first,
              let end = parseTimestamp(String(endField)) else { return nil }
        return (start, end)
    }

    static func parseTimestamp(_ field: String) -> Double? {
        let normalized = field.replacingOccurrences(of: ",", with: ".")
        let pieces = normalized.split(separator: ":")
        guard (2...3).contains(pieces.count) else { return nil }
        var seconds = 0.0
        for piece in pieces {
            guard let value = Double(piece), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}

