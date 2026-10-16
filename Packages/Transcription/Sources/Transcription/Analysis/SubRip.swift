import Foundation

/// Minimal SubRip (.srt) reading and writing, for importing transcripts from other tools
/// (whisper.cpp, MacWhisper) and for comparing against them.
public enum SubRip {
    public struct Cue: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Parses cues; malformed blocks are skipped.
    public static func parse(_ contents: String) -> [Cue] {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]),
                  let end = seconds(parts[1]) else { continue }
            let text = lines[(timingIndex + 1)...]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cues.append(Cue(start: start, end: end, text: text))
        }
        return cues
    }

    /// "hh:mm:ss,mmm" (or with ".") to seconds.
    static func seconds(_ stamp: String) -> Double? {
        let cleaned = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = cleaned.split(separator: ":")
        guard fields.count == 3,
              let hours = Double(fields[0]),
              let minutes = Double(fields[1]),
              let seconds = Double(fields[2].split(separator: " ").first ?? "") else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    public static func format(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func stamp(_ seconds: Double) -> String {
        let millis = Int((max(seconds, 0) * 1000).rounded())
        let h = millis / 3_600_000, m = (millis / 60_000) % 60, s = (millis / 1000) % 60, ms = millis % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

extension Transcript {
    /// The transcript as SubRip cues (one per segment).
    public var subRipCues: [SubRip.Cue] {
        segments.map { SubRip.Cue(start: $0.start, end: $0.end, text: $0.text) }
    }
}
