import Processing
import StudyCore
import SwiftUI

/// Minimal lecture view (M0): the transcript grouped by the slide on screen. The full review
/// screen with slide, player and click-to-seek is M1.
struct LectureDetailView: View {
    @Environment(AppModel.self) private var model
    @FetchOne private var lecture: Lecture?
    @FetchAll private var spans: [LectureDeckSpan]
    @FetchAll private var jobs: [Job]
    private let lectureID: Lecture.ID

    init(lectureID: Lecture.ID) {
        self.lectureID = lectureID
        _lecture = FetchOne(Lecture.find(lectureID))
        _spans = FetchAll(LectureDeckSpan.where { $0.lectureID.eq(lectureID) }.order(by: \.startTime))
        _jobs = FetchAll(Job.where { $0.lectureID.eq(lectureID) }.order(by: \.createdAt))
    }

    var body: some View {
        let deckID = spans.first { !$0.isTimed }?.deckID ?? spans.first?.deckID
        LectureTranscriptList(
            lectureID: lectureID,
            deckID: deckID,
            spans: spans.filter(\.isTimed),
            language: lecture?.language ?? ""
        )
        .id(deckID)
        .navigationTitle(lecture.map { $0.title.isEmpty ? String(localized: "Lecture") : $0.title } ?? "")
        .navigationSubtitle(
            lecture?.heldAt?.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()) ?? ""
        )
        .toolbar {
            if let job = jobs.last {
                ToolbarItem(placement: .primaryAction) {
                    if job.state == .failed || job.state == .cancelled {
                        Button("Retry", systemImage: "arrow.clockwise") { model.retryProcessing(lectureID: lectureID) }
                            .help(job.error ?? "")
                    } else {
                        JobStatusView(job: job)
                    }
                }
            }
        }
    }
}

/// The transcript list itself; its own fetches so job progress does not rebuild it.
private struct LectureTranscriptList: View {
    @FetchAll private var segments: [TranscriptSegment]
    @FetchAll private var pages: [DeckPage]
    let spans: [LectureDeckSpan]
    let language: String

    init(lectureID: Lecture.ID, deckID: Deck.ID?, spans: [LectureDeckSpan], language: String) {
        _segments = FetchAll(TranscriptSegment.where { $0.lectureID.eq(lectureID) }.order(by: \.startTime))
        // Without a deck there are no pages to title the sections with.
        let deck = deckID ?? UUID()
        _pages = FetchAll(DeckPage.where { $0.deckID.eq(deck) }.order(by: \.pageNumber))
        self.spans = spans
        self.language = language
    }

    var body: some View {
        let outline = LectureOutline(segments: segments, spans: spans, pages: pages)
        if outline.sections.isEmpty {
            ContentUnavailableView {
                Image(systemName: "waveform")
            }
        } else {
            List {
                ForEach(outline.sections) { section in
                    Section {
                        ForEach(section.segments) { segment in
                            SegmentRow(segment: segment, lectureLanguage: language)
                        }
                    } header: {
                        SectionHeader(section: section)
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        }
    }
}

private struct SectionHeader: View {
    let section: LectureOutline.Section

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let page = section.page {
                Text("Slide \(page)")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(section.title)
                    .lineLimit(1)
            } else if section.isOffSlide {
                Text("Not on slides")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            if section.source != nil {
                Text("\(TimeText.clock(section.start))–\(TimeText.clock(section.end))")
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let lectureLanguage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(TimeText.clock(segment.startTime))
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Text(segment.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Only lines in another language than the lecture's carry a tag.
            if !segment.lang.isEmpty, segment.lang != lectureLanguage {
                Text(segment.lang.uppercased())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
