import Capture
import CaptureUI
import Notes
import StudyCore
import StudyUI
import SwiftUI

/// The lectures a picker offers: the note's lecture, or (a course note) the course's lectures,
/// newest first.
@MainActor
enum NotePickerLectures {
    static func lectures(courseID: Course.ID?, lectureID: Lecture.ID?, services: StudyServices) async -> [Lecture] {
        do {
            return try await services.database.read { db in
                if let lectureID {
                    return try Lecture.find(lectureID).fetchAll(db)
                }
                guard let courseID else { return [] }
                return try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db)
                    .sorted { ($0.heldAt ?? $0.createdAt, $0.number ?? 0) > ($1.heldAt ?? $1.createdAt, $1.number ?? 0) }
            }
        } catch {
            NotesLog.logger.error("Loading lectures failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// "L2 · Virtualization & IaaS".
    static func label(_ lecture: Lecture) -> String {
        [lecture.number.map { "L\($0)" }, lecture.title.isEmpty ? nil : lecture.title].compactMap(\.self).joined(separator: " · ")
    }
}

// MARK: - Slide

/// Slide (toolbar): the slides of the note's lecture (a course note: its course's lectures, newest
/// first) as thumbnails; a click inserts the slide as a clip at the caret.
struct NoteSlidePicker: View {
    let courseID: Course.ID?
    let lectureID: Lecture.ID?
    let pick: (NoteInline) -> Void

    @Environment(\.studyServices) private var services
    @State private var groups: [SlideGroup] = []
    @State private var isLoaded = false

    struct SlideGroup: Identifiable {
        let lecture: Lecture
        let deckRow: Deck
        let blob: BlobRef
        /// The pages the lecture covered; nil: every page.
        let range: ClosedRange<Int>?
        var id: Lecture.ID { lecture.id }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in
                    if groups.count > 1 {
                        Text(verbatim: NotePickerLectures.label(group.lecture))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    NoteSlideGroupGrid(group: group, pick: pick)
                }
            }
            .padding(12)
        }
        .frame(width: 380, height: 420)
        .overlay {
            if isLoaded, groups.isEmpty {
                ContentUnavailableView {
                    Image(systemName: "rectangle.on.rectangle.slash")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let services else { return }
        let lectures = await NotePickerLectures.lectures(courseID: courseID, lectureID: lectureID, services: services)
        var loaded: [SlideGroup] = []
        for lecture in lectures {
            guard let found = await deck(of: lecture, services: services), let blob = found.0.blob else { continue }
            loaded.append(SlideGroup(lecture: lecture, deckRow: found.0, blob: blob, range: found.1))
        }
        groups = loaded
        isLoaded = true
    }

    /// The lecture's deck and its pages (mr: its range, `LectureSlides.current`), as Review
    /// reads it; without a range, a timed span's deck, whole (a capture's stamped deck).
    private func deck(of lecture: Lecture, services: StudyServices) async -> (Deck, ClosedRange<Int>?)? {
        let lectureID = lecture.id
        do {
            return try await services.database.read { db in
                if let range = try LectureSlides.current(lectureID: lectureID, in: db) {
                    guard let deck = try Deck.find(range.deckID).fetchOne(db) else { return nil }
                    return (deck, range.pages)
                }
                let timed = try LectureDeckSpan
                    .where { $0.lectureID.eq(lectureID) && $0.startTime.isNot(nil) && $0.firstPage.isNot(nil) }
                    .order(by: \.updatedAt)
                    .fetchAll(db)
                guard let span = timed.last, let deck = try Deck.find(span.deckID).fetchOne(db) else { return nil }
                return (deck, nil)
            }
        } catch {
            NotesLog.logger.error("Loading a deck failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// One lecture's slides in the Slide picker. Its PDF opens when the group scrolls into view
/// (placeholders until then), so a course note's picker opens only the decks it shows.
private struct NoteSlideGroupGrid: View {
    let group: NoteSlidePicker.SlideGroup
    let pick: (NoteInline) -> Void

    @Environment(\.studyServices) private var services
    @State private var deck: SlideDeck?
    @State private var failed = false

    private var pages: [Int] {
        let count = deck?.pageCount ?? group.deckRow.pageCount
        guard count >= 1 else { return [] }
        let all = group.range.map { Array($0) } ?? Array(1...count)
        return all.filter { $0 >= 1 && $0 <= count }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)], spacing: 8) {
            if !failed {
                ForEach(pages, id: \.self) { page in
                    if let deck {
                        Button {
                            pick(NoteMedia.slideClip(
                                deck: group.deckRow, page: page, lectureID: group.lecture.id,
                                aspectRatio: Double(deck.aspectRatio(page: page))
                            ))
                        } label: {
                            thumbnail(page) {
                                SlideImageView(deck: deck, page: page, pixelWidth: SlideWidth.thumbnail, cornerRadius: 3)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Slide \(page)"))
                    } else {
                        thumbnail(page) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(.quaternary)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        }
                    }
                }
            }
        }
        .task(id: group.blob.sha256) {
            guard let services, deck == nil else { return }
            deck = await NoteDeckCache.deck(blob: group.blob, services: services)
            failed = deck == nil
        }
    }

    private func thumbnail(_ page: Int, @ViewBuilder image: () -> some View) -> some View {
        VStack(spacing: 3) {
            image()
            Text(verbatim: "\(page)")
                .font(.chip)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Quote

/// Quote (toolbar): the note's lecture's transcript lines (a course note: its course's lectures,
/// newest first) under a filter field; a click inserts the line as a professor quote.
struct NoteQuotePicker: View {
    let courseID: Course.ID?
    let lectureID: Lecture.ID?
    let pick: (NoteBlock) -> Void

    @Environment(\.studyServices) private var services
    @State private var lines: [Line] = []
    @State private var filter = ""
    @State private var isLoaded = false

    struct Line: Identifiable {
        let segment: TranscriptSegment
        let lecture: Lecture
        let folded: String
        var id: TranscriptSegment.ID { segment.id }
    }

    private var shown: [Line] {
        let terms = filter.split(whereSeparator: \.isWhitespace).map { NoteList.fold(String($0)) }
        guard !terms.isEmpty else { return lines }
        return lines.filter { line in terms.allSatisfy { line.folded.contains($0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Hairline()
            let shown = shown
            let multiple = Set(lines.map(\.lecture.id)).count > 1
            List(shown) { line in
                Button {
                    pick(NoteMedia.quote(line.segment, lectureID: line.lecture.id))
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: multiple ? "\(line.lecture.number.map { "L\($0) · " } ?? "")\(TimeText.clock(line.segment.startTime))" : TimeText.clock(line.segment.startTime))
                            .font(.mono(11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .leading)
                        Text(verbatim: line.segment.text)
                            .font(.system(size: 12.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay {
                if isLoaded, shown.isEmpty {
                    if filter.isEmpty {
                        ContentUnavailableView { Image(systemName: "waveform") }
                    } else {
                        ContentUnavailableView.search(text: filter)
                    }
                }
            }
        }
        .frame(width: 420, height: 420)
        .task { await load() }
    }

    private func load() async {
        guard let services else { return }
        let lectures = await NotePickerLectures.lectures(courseID: courseID, lectureID: lectureID, services: services)
        let repository = TranscriptRepository(store: services.records)
        var loaded: [Line] = []
        for lecture in lectures {
            let segments = (try? await repository.segments(lectureID: lecture.id)) ?? []
            loaded += segments
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { Line(segment: $0, lecture: lecture, folded: NoteList.fold($0.text)) }
        }
        lines = loaded
        isLoaded = true
    }
}
