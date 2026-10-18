import Foundation
import SQLiteData

// Values added with schema v8 (M4: the AI study pass). docs/plan-m4.md §2, docs/schema.md.
//
// What the pass writes, all in `annotation` (one reader serves Review, the pins, Today, the coach):
// - ai · summary          a slide's summary (page set) or the lecture's (page nil)
// - ai · not_on_slides    said in class, not on the slides (`category`)
// - professor · exam_hint the professor's exact words with an exam cue nearby (`anchor_text`)
// - professor · highlight the professor's exact words they stressed, no exam cue (`anchor_text`)
// - ai · further_reading  a verified web source (body = title, `detail` = byline)
// - ai · topic            a topic of the lecture (pages `page_number…last_page`), coach data
// - user · comment        the student's own pin (`anchor_x`/`anchor_y`)

extension AnnotationKind {
    /// What the professor stressed without an exam cue nearby (professor layer): body is the exact
    /// quote, as for `examHint`, but no star.
    public static let highlight: Self = "highlight"
    /// A topic of the lecture (ai layer): body ≤ 8 words, slides `page_number…last_page`,
    /// `start_time` where it was explained. Read by the study coach; not shown in M4.
    public static let topic: Self = "topic"

    /// The professor's own words (exam hints and highlights): Today's "N highlights".
    public var isProfessorItem: Bool { self == .examHint || self == .highlight }
}

/// What a "said in class, not on the slides" item is about (v8 `annotation.category`).
public struct SaidInClassCategory: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Organisation: exam admission, office hours, where the slides are.
    public static let admin: Self = "admin"
    /// An example the slides do not have.
    public static let example: Self = "example"
    /// A question from the room and its answer.
    public static let question: Self = "question"
    /// An explanation that goes beyond the slide text.
    public static let explanation: Self = "explanation"
    /// A date or due moment. Shown, never written as a tracked item here (M3's transcript
    /// pipeline owns deadlines).
    public static let deadline: Self = "deadline"

    /// The order of "Whole lecture"'s subheadlines (Admin, Deadlines, Questions, Examples,
    /// Explanations); unknown categories go last.
    public static let displayOrder: [Self] = [.admin, .deadline, .question, .example, .explanation]
}

/// A stage of the study pass (v8 `study_unit.stage`). docs/plan-m4.md §3.
public struct StudyStage: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Haiku reads a block of slides and its lines: corrections, slide summaries, figure lines,
    /// candidates.
    public static let read: Self = "read"
    /// Opus, once per lecture: exam hints, highlights, said in class, topics, the lecture summary,
    /// research picks.
    public static let synthesize: Self = "synthesize"
    /// Haiku with Claude Code's WebSearch/WebFetch only, one per picked topic: further reading.
    public static let research: Self = "research"

    /// `api_call.purpose` prefix of the study pass's calls.
    public static let callPurposePrefix = "study."

    /// `api_call.purpose` of this stage's calls: "study.read", "study.synthesize",
    /// "study.research" (always with `lecture_id`).
    public var callPurpose: String { Self.callPurposePrefix + rawValue }
}

/// One correction of a transcript line, as a patch on its `original_text` (v8
/// `transcript_segment.patches`, JSON `[TranscriptPatch]`).
///
/// `text` is always `TranscriptPatch.apply(patches, to: original_text)`; `original_text` is never
/// touched (use `TranscriptSegment.withPatches`). The study pass reads `original_text`, so its
/// corrections are always relative to it. A re-transcription replaces the rows and with them the
/// patches. A patch without `apiCallID` is the student's own.
public struct TranscriptPatch: Hashable, Sendable, Codable {
    /// Characters (grapheme clusters) from the start of `original_text` to the first character of
    /// `from`.
    public var offset: Int
    /// The exact span of `original_text` at `offset` that is replaced.
    public var from: String
    /// What the line reads instead.
    public var to: String
    /// The call that proposed it; nil for the student's own correction.
    public var apiCallID: APICall.ID?
    /// Set by Revert Correction: the patch stays (so a re-run keeps it reverted) but is not applied.
    public var revertedAt: Date?

    public init(offset: Int, from: String, to: String, apiCallID: APICall.ID? = nil, revertedAt: Date? = nil) {
        self.offset = offset
        self.from = from
        self.to = to
        self.apiCallID = apiCallID
        self.revertedAt = revertedAt
    }

    enum CodingKeys: String, CodingKey {
        case offset, from, to
        case apiCallID = "api_call_id"
        case revertedAt = "reverted_at"
    }

    /// Applied unless reverted.
    public var isActive: Bool { revertedAt == nil }

    /// A piece of a patched line, for drawing it: plain text, or a correction (~~from~~ + to).
    public enum Run: Hashable, Sendable {
        case text(String)
        /// `patch` is the index of the patch in the array given to `runs`.
        case corrected(from: String, to: String, patch: Int)
    }

    /// `original` with every active patch that still matches applied. A patch whose `from` is not
    /// at its `offset`, or that overlaps an earlier one, is skipped.
    public static func apply(_ patches: [TranscriptPatch], to original: String) -> String {
        runs(patches, in: original).reduce(into: "") { text, run in
            switch run {
            case .text(let plain): text += plain
            case .corrected(_, let to, _): text += to
            }
        }
    }

    /// `original` cut into plain runs and the active patches that match, in order.
    public static func runs(_ patches: [TranscriptPatch], in original: String) -> [Run] {
        var runs: [Run] = []
        var cursor = original.startIndex
        var cursorOffset = 0
        let order = patches.indices
            .filter { patches[$0].isActive && !patches[$0].from.isEmpty }
            .sorted { patches[$0].offset < patches[$1].offset }
        for index in order {
            let patch = patches[index]
            guard patch.offset >= cursorOffset,
                  let start = original.index(cursor, offsetBy: patch.offset - cursorOffset, limitedBy: original.endIndex),
                  let end = original.index(start, offsetBy: patch.from.count, limitedBy: original.endIndex),
                  original[start..<end] == patch.from
            else { continue }
            if cursor < start { runs.append(.text(String(original[cursor..<start]))) }
            runs.append(.corrected(from: patch.from, to: patch.to, patch: index))
            cursor = end
            cursorOffset = patch.offset + patch.from.count
        }
        if cursor < original.endIndex { runs.append(.text(String(original[cursor...]))) }
        return runs
    }
}

extension TranscriptSegment {
    /// The patches in effect (nil column = none).
    public var activePatches: [TranscriptPatch] { (patches ?? []).filter(\.isActive) }

    /// This line with `patches` stored and `text` recomputed from `originalText`; `revision` goes
    /// up when the text changes. Save the result (`RecordStore.save` / upsert); never set `text`
    /// by hand.
    public func withPatches(_ patches: [TranscriptPatch]) -> TranscriptSegment {
        var segment = self
        segment.patches = patches.isEmpty ? nil : patches
        let text = TranscriptPatch.apply(patches, to: originalText)
        if text != segment.text { segment.revision += 1 }
        segment.text = text
        return segment
    }
}
