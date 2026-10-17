import Alignment
import Foundation
import StudyCore

/// StudyCore rows ↔ the aligner's value types (the Alignment package does not know StudyCore).
public enum AlignmentMapping {
    public static func slides(_ pages: [DeckPage]) -> [SlideText] {
        pages.sorted { $0.pageNumber < $1.pageNumber }.map { SlideText(page: $0.pageNumber, text: $0.text) }
    }

    public static func transcript(_ segments: [TranscriptSegment]) -> [TranscriptLine] {
        segments.sorted { $0.startTime < $1.startTime }.map { segment in
            TranscriptLine(
                start: segment.startTime,
                end: segment.endTime,
                text: segment.text,
                words: (segment.words ?? []).map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
            )
        }
    }

    /// Anchors from a recording's events: slide stamps (`show`, snapped by the aligner) and manual
    /// "slide starts here" markers (used as given). Flags and events for other decks are ignored,
    /// as are pages outside `validPages`.
    public static func anchors(
        events: [SlideEvent],
        sampleRate: Double,
        deckID: Deck.ID,
        validPages: Set<Int>
    ) -> [AlignmentAnchor] {
        guard sampleRate > 0 else { return [] }
        return events.compactMap { event in
            guard let sample = event.sampleTime, event.deckID == nil || event.deckID == deckID else { return nil }
            let time = Double(sample) / sampleRate
            switch event.kind {
            case .show:
                guard let page = event.pageNumber, validPages.contains(page) else { return nil }
                return .stamp(page, at: time)
            case .manual:
                if let page = event.pageNumber {
                    return validPages.contains(page) ? .manual(.slide(page), at: time) : nil
                }
                return .manual(.off, at: time)
            default:
                return nil
            }
        }
    }

    public static func source(_ origin: SpanOrigin) -> SpanSource {
        switch origin {
        case .automatic: .auto
        case .stamp: .stamp
        case .manual: .manual
        }
    }

    /// One `lecture_deck_span` row per aligned span; OFF spans have no pages.
    public static func spans(
        _ result: AlignmentResult,
        lectureID: Lecture.ID,
        deckID: Deck.ID,
        recordingID: Recording.ID
    ) -> [LectureDeckSpan] {
        result.spans.map { span in
            LectureDeckSpan(
                lectureID: lectureID,
                deckID: deckID,
                firstPage: span.target.page,
                lastPage: span.target.page,
                recordingID: recordingID,
                startTime: span.start,
                endTime: span.end,
                source: source(span.origin),
                confidence: span.confidence
            )
        }
    }
}
