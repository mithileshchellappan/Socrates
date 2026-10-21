#if os(macOS)
import SQLiteData
import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

/// A lecture's notes (docs/plan-lecture-notes.md): one study text Claude wrote, read on the
/// course's Lectures page (`.page`) and in Review's Whole lecture pane (`.inspector`): ONE
/// read-only TextKit 2 document, so a selection spans paragraphs and figures.
///
/// - The outline (from the version's sections) shows before the text; while it is written, the
///   text arrives in place under one determinate "Writing" line, typed blocks keep a placeholder
///   height until their fence closes, and nothing being read moves. Queued: the skeleton;
///   paused: "Paused until 17:20"; failed: what came, a triangle with the reason, Write Again….
/// - Sections fold by a chevron in the margin (kept per lecture).
/// - A settled selection floats the capsule [highlighter] [Ask]; its menu starts with Ask… and
///   Highlight / Remove Highlight. Ask (through `\.lectureNotesAsker`; nil: Highlight only) opens
///   the popover; Keep adds the answer under its paragraph; Continue in Chat opens the panel with
///   the passage as its context: published by the view (`.agentContext`), or handed to the host
///   (`onChatPassage`, Review). It goes with the next message only.
/// - Chips call `onChip` first (Review moves its own review); else Review opens at the slide or
///   plays from the moment.
///
/// The view is as tall as its text (the host scrolls); it hangs its fold chevrons 18 pt into the
/// margin on both sides. It does not queue notes: the page and the pane do (`queueIfNeeded`).
public struct LectureNotesView: View {
    private let lectureID: Lecture.ID
    private let style: LectureNotesStyle
    private let followPage: Int?
    private let onChip: ((NotesChipTarget) -> Bool)?
    private let writeAgain: (() -> Void)?
    private let onChatPassage: ((NotesPassageContext?) -> Void)?

    @Fetch private var rows: LectureNotesRows
    @State private var controller: LectureNotesController
    @State private var height: CGFloat = 120
    @State private var followed: String?
    @State private var followSettled = false
    @Environment(\.studyServices) private var services
    @Environment(\.openDestination) private var openDestination
    @Environment(\.openAgentPanel) private var openAgentPanel
    @Environment(\.lectureNotesAsker) private var asker
    @Environment(\.lectureNotesUnavailable) private var unavailable
    @Environment(\.lectureNotesPreview) private var preview
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.undoManager) private var undoManager

    /// - Parameters:
    ///   - followPage: Review's slide on screen while Follow is on: the view scrolls to the section
    ///     whose slides hold it (nil: no following).
    ///   - onChip: a chip was clicked; return true when the host handled it.
    ///   - writeAgain: a failed version's Write Again… (the page's popover); nil: queued at once.
    ///   - onChatPassage: Continue in Chat's passage for the host to send with its own context (nil
    ///     when it should stop going); nil: the view publishes it (`.agentContext`).
    public init(
        lectureID: Lecture.ID, style: LectureNotesStyle = .page, followPage: Int? = nil,
        onChip: ((NotesChipTarget) -> Bool)? = nil, writeAgain: (() -> Void)? = nil,
        onChatPassage: ((NotesPassageContext?) -> Void)? = nil
    ) {
        self.lectureID = lectureID
        self.style = style
        self.followPage = followPage
        self.onChip = onChip
        self.writeAgain = writeAgain
        self.onChatPassage = onChatPassage
        _rows = Fetch(wrappedValue: .empty, LectureNotesRequest(lectureID: lectureID))
        _controller = State(initialValue: LectureNotesController(lectureID: lectureID, style: style))
    }

    public var body: some View {
        let controller = controller
        let input = makeInput()
        controller.services = services
        // Renders: the preview's canned Ask (the capsule's [Ask], the popover's one exchange).
        controller.asker = preview?.passage != nil ? CannedNotesAsker(answer: preview?.answer ?? "") : asker
        controller.openDestination = openDestination
        controller.openAgentPanel = openAgentPanel
        controller.onChip = onChip
        controller.onWriteAgain = writeAgain
        controller.onChatPassage = onChatPassage
        controller.undoManager = undoManager
        controller.notes = input.notes
        controller.marks = input.marks
        controller.chips = input.chips
        return NotesTextHost(input: input, controller: controller) { height = $0 }
            .frame(height: max(20, height))
            .padding(.horizontal, -NotesTextView.chevronMargin)
            .focusedSceneValue(\.lectureNotesAsk, controller.askCommand)
            .focusedSceneValue(\.lectureNotesHighlight, controller.highlightCommand)
            .preference(key: AgentContextPreferenceKey.self, value: chatContext)
            .onDisappear { if controller.chatPassage != nil { controller.chatPassage = nil } }
            .onChange(of: followPage, initial: true) { follow() }
            // The first follow waits for the text's real height.
            .onChange(of: height) { if !followSettled { follow(force: true) } }
            .task(id: preview) { await showPreview() }
            .accessibilityElement(children: .contain)
    }

    private func makeInput() -> NotesDocumentInput {
        let rows = rows
        let current = LectureNotes.current(of: rows.versions)
        var lectures: [String: NotesDocumentInput.LectureRef] = [:]
        for lecture in rows.lectures {
            lectures[ChatCitation.key(lecture.id)] = NotesDocumentInput.LectureRef(id: lecture.id, number: lecture.number)
        }
        lectures[ChatCitation.key(lectureID)] = NotesDocumentInput.LectureRef(id: lectureID, number: rows.lecture?.number)
        var recordings: [String: Recording.ID] = [:]
        for recording in rows.recordings { recordings[ChatCitation.key(recording.id)] = recording.id }
        let professor = rows.course?.professors.first.map { String(localized: "Prof. \(SourceTrailText.surname($0))") }
        return NotesDocumentInput(
            lectureID: lectureID, style: style, isDark: colorScheme == .dark, notes: current,
            marks: rows.marks.filter { $0.removedAt == nil }, studentNotes: rows.notes, quotes: rows.quotes, lectures: lectures,
            recordings: recordings, hasRecording: !rows.recordings.isEmpty, deck: rows.deck,
            pages: rows.range.map { $0.firstPage...$0.lastPage }, professor: professor, folded: controller.folded,
            answersOpen: controller.answersOpen, unavailable: unavailable
        )
    }

    /// The passage taken to the chat, published while no host takes it (the page). `refine` runs
    /// once, when a message reads the context: the passage goes with that message only.
    private var chatContext: AgentContextSource? {
        guard onChatPassage == nil, let passage = controller.chatPassage else { return nil }
        let context = switch style {
        case .page:
            AgentContext(screen: .course, courseID: rows.lecture?.courseID, courseScreen: "lecture_notes", lectureID: lectureID, notesPassage: passage)
        case .inspector:
            AgentContext(screen: .lecture, courseID: rows.lecture?.courseID, lectureID: lectureID, page: followPage, notesPassage: passage)
        }
        let controller = controller
        let screen = context.screen
        return AgentContextSource(context: context) {
            controller.chatPassageSent()
            return AgentContext(screen: screen)
        }
    }

    /// Renders: the preview's selection, capsule, popover or scroll, once the text is there.
    private func showPreview() async {
        guard let preview else { return }
        for _ in 0..<50 {
            if let coordinator = controller.coordinator {
                coordinator.showPreview(preview)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Follow: the section whose slides hold Review's slide on screen comes to the top (once per
    /// section).
    private func follow(force: Bool = false) {
        guard let page = followPage, let notes = LectureNotes.current(of: rows.versions), notes.hasText,
              let section = notes.sections.first(where: { $0.covers(page: page) })
                ?? notes.sections.last(where: { ($0.firstPage ?? .max) <= page })
        else { return }
        guard force || followed != section.key else { return }
        followed = section.key
        if height > 200 { followSettled = true }
        Task { @MainActor in controller.coordinator?.scroll(toSection: section.key) }
    }
}

/// The rows the notes are drawn from, in one observed read: every version, the student's marks
/// and notes, the professor's exam hints and highlights, the lecture with its course's lectures,
/// recordings and slides.
struct LectureNotesRows: Equatable, Sendable {
    var versions: [LectureNotes] = []
    var marks: [LectureNotesMark] = []
    var notes: [Note] = []
    var quotes: [Annotation] = []
    var lecture: Lecture?
    var course: Course?
    var lectures: [Lecture] = []
    var recordings: [Recording] = []
    var range: LectureSlideRange?
    var deck: Deck?

    static let empty = LectureNotesRows()
}

struct LectureNotesRequest: FetchKeyRequest {
    let lectureID: Lecture.ID

    func fetch(_ db: Database) throws -> LectureNotesRows {
        let id = lectureID
        let reference = Lecture.ID?.some(id)
        var rows = LectureNotesRows()
        rows.versions = try LectureNotesRepository.versions(lectureID: id, in: db)
        rows.marks = try LectureNotesMark.where { $0.lectureID.eq(id) && $0.removedAt.is(nil) }.order { $0.createdAt.asc() }.fetchAll(db)
        rows.notes = try Note.where { $0.lectureID.eq(reference) }.order { ($0.pageNumber, $0.createdAt) }.fetchAll(db)
        rows.quotes = try Annotation
            .where { $0.lectureID.eq(reference) && $0.hiddenAt.is(nil) && $0.kind.in([AnnotationKind.examHint, AnnotationKind.highlight]) }
            .fetchAll(db)
        rows.lecture = try Lecture.find(id).fetchOne(db)
        if let lecture = rows.lecture {
            let courseID = lecture.courseID
            rows.course = try Course.find(courseID).fetchOne(db)
            rows.lectures = try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db)
        }
        rows.recordings = try Recording.where { $0.lectureID.eq(reference) }.order { $0.startedAt.asc() }.fetchAll(db)
        rows.range = try LectureSlides.current(lectureID: id, in: db)
        if let deckID = rows.range?.deckID {
            rows.deck = try Deck.find(deckID).fetchOne(db)
        }
        return rows
    }
}
#endif
