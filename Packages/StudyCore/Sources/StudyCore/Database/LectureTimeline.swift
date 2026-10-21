import Foundation
import SQLiteData

/// A lecture's recordings on one timeline (decisions 2026-10-21, "Every recording of a lecture"):
/// what the study pass, the lecture notes and the notes' outline put in order. Each recording keeps
/// its own clock (an annotation's `start_time`, a moment chip and Review stay on it); the timeline
/// places sample 0 of each recording at its offset from the earliest recording with transcript
/// lines. With one recording the timeline is that recording's clock.
public struct LectureTimeline: Sendable, Hashable {
    /// The lecture's first recording by `started_at`: a moment chip without a recording key names it.
    public var first: Recording.ID?
    /// Seconds from the timeline's zero to each recording's sample 0.
    public var offsets: [Recording.ID: Double]
    /// The stretch of each recording with transcript lines (sample 0 to the end of its audio or of
    /// its last line), in timeline seconds.
    public var spans: [Recording.ID: ClosedRange<Double>]

    public init(first: Recording.ID? = nil, offsets: [Recording.ID: Double] = [:], spans: [Recording.ID: ClosedRange<Double>] = [:]) {
        self.first = first
        self.offsets = offsets
        self.spans = spans
    }

    /// `time` on `recording`'s clock in timeline seconds (nil: the lecture's first recording; a
    /// recording the timeline does not know: its own clock).
    public func seconds(_ time: Double, on recording: Recording.ID?) -> Double {
        guard let id = recording ?? first, let offset = offsets[id] else { return time }
        return offset + time
    }

    /// Whether two recording ids name the same recording (nil: the lecture's first).
    public func same(_ lhs: Recording.ID?, _ rhs: Recording.ID?) -> Bool {
        (lhs ?? first) == (rhs ?? first)
    }

    /// Seconds the recordings with lines cover, overlapping stretches once.
    public var coveredSeconds: Double {
        var total = 0.0
        var current: ClosedRange<Double>?
        for span in spans.values.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let open = current, span.lowerBound <= open.upperBound {
                current = open.lowerBound...max(open.upperBound, span.upperBound)
            } else {
                if let open = current { total += open.upperBound - open.lowerBound }
                current = span
            }
        }
        if let open = current { total += open.upperBound - open.lowerBound }
        return total
    }

    /// Where the last recording with lines ends, in timeline seconds (0 without one).
    public var end: Double {
        spans.values.map(\.upperBound).max() ?? 0
    }

    /// The lecture's timeline from its recordings (and, with more than one, its transcript lines).
    public static func load(lectureID: Lecture.ID, in db: Database) throws -> LectureTimeline {
        let reference = Lecture.ID?.some(lectureID)
        let recordings = try Recording.where { $0.lectureID.eq(reference) }.fetchAll(db)
        guard recordings.count > 1 else { return LectureRecordingMerge.merge(recordings: recordings, segments: []).timeline }
        let segments = try TranscriptSegment
            .where { $0.lectureID.eq(reference) }
            .order(by: \.startTime)
            .fetchAll(db)
            .filter(LectureRecordingMerge.isSpoken)
        return LectureRecordingMerge.merge(recordings: recordings, segments: segments).timeline
    }
}

/// A lecture's transcript lines from all its recordings, in timeline order (`LectureTimeline`):
///
/// - Recordings are placed by `started_at`. Recordings one after the other (Stop and Record
///   again, a second part) follow each other on the timeline.
/// - Two recordings whose stretches overlap are the same speech recorded twice (two devices at
///   once). Each stretch both cover keeps the lines of the recording with more spoken words in it
///   (more words: fewer gaps, drop-outs and hallucinated silences; a tie goes to the higher mean
///   confidence, then to the earlier recording), and the other's lines whose middle lies in that
///   stretch are left out: nothing is said twice.
/// - Unless their transcripts clearly disagree there (both sides have at least `minimumTrigrams`
///   word trigrams in the shared stretch and under `agreement` of the smaller side's are shared):
///   then the overlap is a start that is not the recording's own (two files copied at once carry
///   the copy's date) and that recording is placed after the end of the ones before it, as the
///   next part. Too few words to judge counts as the same speech.
public struct LectureRecordingMerge: Sendable {
    public var timeline: LectureTimeline
    /// The kept lines, in timeline order.
    public var segments: [TranscriptSegment]
    /// The recordings with kept lines, in timeline order.
    public var recordings: [Recording.ID]
    /// Lines left out because another recording had the same stretch with more words.
    public var dropped: Int
    /// Stretches that two recordings of the same speech shared.
    public var overlaps: Int
    /// Recordings placed after the ones before them (their times overlapped, their speech did not).
    public var moved: Int

    /// Shared word trigrams (of the side with fewer) under which two overlapping recordings with
    /// `minimumTrigrams` each say different things (Whisper on the same speech shares far more).
    public static let agreement = 0.2
    public static let minimumTrigrams = 10

    /// A line with words (the readers' rule: empty lines are no lines).
    public static func isSpoken(_ segment: TranscriptSegment) -> Bool {
        !segment.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `recordings`: the lecture's recordings (all of them: the first by `started_at` is the one
    /// chips name without a key); `segments`: its spoken lines in start order.
    public static func merge(recordings: [Recording], segments: [TranscriptSegment]) -> LectureRecordingMerge {
        let rows = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let first = recordings.min { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }?.id
        var lines: [Recording.ID: [TranscriptSegment]] = [:]
        var withLines: [Recording.ID] = []
        for segment in segments {
            if lines[segment.recordingID] == nil { withLines.append(segment.recordingID) }
            lines[segment.recordingID, default: []].append(segment)
        }
        // Zero: the earliest recording with lines (a line whose recording has no row sits there).
        let zero = withLines.compactMap { rows[$0]?.startedAt }.min() ?? recordings.map(\.startedAt).min()
        func nominal(_ id: Recording.ID) -> Double {
            guard let zero, let start = rows[id]?.startedAt else { return 0 }
            return start.timeIntervalSince(zero)
        }
        func extent(_ id: Recording.ID) -> Double {
            max(rows[id]?.duration ?? 0, lines[id]?.map(\.endTime).max() ?? 0)
        }
        var offsets: [Recording.ID: Double] = [:]
        for recording in recordings { offsets[recording.id] = nominal(recording.id) }

        let ordered = withLines.sorted { (nominal($0), $0.uuidString) < (nominal($1), $1.uuidString) }
        guard ordered.count > 1 else {
            // One recording (or none): its lines in start order, its clock the timeline.
            var spans: [Recording.ID: ClosedRange<Double>] = [:]
            if let only = withLines.first {
                spans[only] = nominal(only)...(nominal(only) + extent(only))
            }
            return LectureRecordingMerge(
                timeline: LectureTimeline(first: first, offsets: offsets, spans: spans),
                segments: segments.sorted { $0.startTime < $1.startTime }, recordings: withLines, dropped: 0, overlaps: 0, moved: 0
            )
        }

        // Placing: by start; an overlap whose speech clearly differs moves the later recording on.
        struct Placed {
            var id: Recording.ID
            var start: Double
            var end: Double
            var rank: Int
        }
        var placed: [Placed] = []
        var sameSpeech: Set<[Recording.ID]> = []
        var moved = 0
        for (rank, id) in ordered.enumerated() {
            var start = nominal(id)
            let length = extent(id)
            let overlapping = placed.filter { $0.start < start + length && start < $0.end }
            if !overlapping.isEmpty {
                let candidate = Placed(id: id, start: start, end: start + length, rank: rank)
                let agreeing = overlapping.filter { other in
                    !disagree(lines[id] ?? [], candidate.start...candidate.end, lines[other.id] ?? [], other.start...other.end)
                }
                if agreeing.isEmpty {
                    start = max(start, placed.map(\.end).max() ?? start)
                    moved += 1
                } else {
                    for other in agreeing { sameSpeech.insert(pair(id, other.id)) }
                }
            }
            placed.append(Placed(id: id, start: start, end: start + length, rank: rank))
            offsets[id] = start
        }

        // Each stretch two recordings of the same speech share keeps the one with more words.
        var left: Set<TranscriptSegment.ID> = []
        var overlaps = 0
        if !sameSpeech.isEmpty {
            let cuts = Set(placed.flatMap { [$0.start, $0.end] }).sorted()
            func stretch(_ time: Double) -> Int {
                var index = 0
                while index + 1 < cuts.count - 1, cuts[index + 1] <= time { index += 1 }
                return index
            }
            var byStretch: [Recording.ID: [Int: [TranscriptSegment]]] = [:]
            for item in placed {
                for segment in lines[item.id] ?? [] {
                    byStretch[item.id, default: [:]][stretch(item.start + (segment.startTime + segment.endTime) / 2), default: []].append(segment)
                }
            }
            for index in 0..<max(0, cuts.count - 1) {
                let lower = cuts[index]
                let upper = cuts[index + 1]
                let active = placed.filter { $0.start <= lower && $0.end >= upper }
                guard active.count > 1 else { continue }
                // More words, then the higher mean confidence, then the earlier recording.
                func score(_ item: Placed) -> (Int, Double, Int) {
                    let said = byStretch[item.id]?[index] ?? []
                    let count = said.reduce(0) { $0 + Self.words(of: $1.originalText).count }
                    let known = said.compactMap(\.confidence)
                    let confidence = known.isEmpty ? -1 : known.reduce(0, +) / Double(known.count)
                    return (count, confidence, -item.rank)
                }
                guard let best = active.max(by: { score($0) < score($1) }) else { continue }
                let losers = active.filter { $0.id != best.id && sameSpeech.contains(pair(best.id, $0.id)) }
                guard !losers.isEmpty else { continue }
                overlaps += 1
                for loser in losers {
                    for segment in byStretch[loser.id]?[index] ?? [] { left.insert(segment.id) }
                }
            }
        }

        // The kept lines in timeline order (a tie: the earlier recording, then start order).
        var timed: [(clock: Double, rank: Int, position: Int, segment: TranscriptSegment)] = []
        for item in placed {
            for (position, segment) in (lines[item.id] ?? []).enumerated() where !left.contains(segment.id) {
                timed.append((item.start + segment.startTime, item.rank, position, segment))
            }
        }
        timed.sort { ($0.clock, $0.rank, $0.position) < ($1.clock, $1.rank, $1.position) }
        var spans: [Recording.ID: ClosedRange<Double>] = [:]
        for item in placed { spans[item.id] = item.start...item.end }
        let kept = Set(timed.map(\.segment.recordingID))
        let recordings = placed.sorted { ($0.start, $0.rank) < ($1.start, $1.rank) }.map(\.id).filter(kept.contains)
        return LectureRecordingMerge(
            timeline: LectureTimeline(first: first, offsets: offsets, spans: spans), segments: timed.map(\.segment),
            recordings: recordings, dropped: left.count, overlaps: overlaps, moved: moved
        )
    }

    /// Whether two recordings clearly say different things in the stretch both cover (their lines
    /// placed at the given spans): enough words on both sides, few word trigrams shared.
    static func disagree(
        _ lhs: [TranscriptSegment], _ lhsSpan: ClosedRange<Double>, _ rhs: [TranscriptSegment], _ rhsSpan: ClosedRange<Double>
    ) -> Bool {
        let lower = max(lhsSpan.lowerBound, rhsSpan.lowerBound)
        let upper = min(lhsSpan.upperBound, rhsSpan.upperBound)
        guard upper > lower else { return false }
        func trigrams(_ lines: [TranscriptSegment], start: Double) -> Set<String> {
            let said = lines.filter { segment in
                let middle = start + (segment.startTime + segment.endTime) / 2
                return middle >= lower && middle <= upper
            }
            let all = said.flatMap { words(of: $0.originalText) }
            guard all.count >= 3 else { return [] }
            return Set((0...(all.count - 3)).map { all[$0] + " " + all[$0 + 1] + " " + all[$0 + 2] })
        }
        let first = trigrams(lhs, start: lhsSpan.lowerBound)
        let second = trigrams(rhs, start: rhsSpan.lowerBound)
        let smaller = min(first.count, second.count)
        guard smaller >= minimumTrigrams else { return false }
        return Double(first.intersection(second).count) / Double(smaller) < agreement
    }

    /// Lower-case words without accents (letters and digits).
    static func words(of text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func pair(_ lhs: Recording.ID, _ rhs: Recording.ID) -> [Recording.ID] {
        lhs.uuidString < rhs.uuidString ? [lhs, rhs] : [rhs, lhs]
    }
}
