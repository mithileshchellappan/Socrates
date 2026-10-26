import SwiftUI
#if os(macOS)
import Courses
import StudyCore
import StudyPageUI
import StudyUI

/// A lecture's notes, pushed full width on its course's Lectures (ln, docs/plan-lecture-notes.md
/// "Build plan", decision 1; nl, docs/plan-notes-layout.md; mockups 30–35). Three zones: the
/// header (title; "Lecture 3 · Mon 19 Oct · 1:29:36 · slides 1–42"; [Open in Review] filled,
/// [Practice], ⋯ with Write Again…, Previous Version, Edit as Note, Copy as Markdown), the notes
/// (`LectureNotesView`), Keep in mind (the lecture's tracked items) at the end. The first open of
/// a lecture without notes queues them (`queueIfNeeded`), except where `\.lectureNotesQueuesOnOpen`
/// is off (renders). Write Again… (the ⋯ menu, the failure line) opens its popover hung off a
/// plain view behind the ⋯ (a popover on the `Menu` itself does not show reliably), after the
/// click, filled with the student's standing instruction; a version without text is queued again
/// at once with it. It is off while a version is open or nothing could be written (no slides with
/// pages, no transcript). While the recording's way into the Summary is blocked, the notes show
/// its line (Retry: `\.lectureNotesRetry`), and the page asks for a version again when that state
/// changes (it writes from what there is, or catches up once the recording is ready).
///
/// nl: the page grows with the window (`NotesPageLayout`): the text at most 780 pt, code, tables,
/// diagrams, charts and slides breaking out to at most 1120, the header and Keep in mind at the
/// text's measure; 52 pt margins (22 under 640 pt of page). While a divider or the window's edge
/// is dragged (`\.isLiveResizing`) the layout keeps the width it had and takes the new one once,
/// when the drag ends. Your notes (`YourNotesColumn`) is the page's side pane (`.yourNotes`); the
/// window keeps its layout per screen kind. While a note there is being typed in, or the search
/// field has the keyboard, ↩ (Open in Review) stands down; the notes' ⌘K / ⇧⌘E attach only while
/// the notes themselves have the keyboard. View ▸ Zoom In / Out scale the content (title, meta,
/// notes, Keep in mind, the pane's notes), never the buttons.
public struct LectureNotesPage: View {
    private let lectureID: Lecture.ID
    @Fetch private var page: LectureNotesPageData
    @State private var writeAgainShown = false
    @State private var request = ""
    @State private var editing = false
    /// The page's width as last laid out (held while a drag resizes the window or a pane).
    @State private var pageWidth: CGFloat = 0
    /// What the page shares with its Your notes pane, which is drawn in another hosting view.
    @State private var state = LectureNotesPageState()
    @Environment(\.studyServices) private var services
    @Environment(\.openDestination) private var openDestination
    @Environment(\.studyCoach) private var studyCoach
    @Environment(\.undoManager) private var undoManager
    @Environment(\.lectureNotesQueuesOnOpen) private var queuesOnOpen
    @Environment(\.lectureNotesRetry) private var retry
    @Environment(\.isSearchFieldFocused) private var isSearchFieldFocused
    @Environment(\.isLiveResizing) private var isLiveResizing
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    public init(lectureID: Lecture.ID) {
        self.lectureID = lectureID
        _page = Fetch(wrappedValue: .empty, LectureNotesPageRequest(lectureID: lectureID))
    }

    public var body: some View {
        let state = state
        let lectureID = lectureID
        ZoomReader { zoom in
            content(zoom: zoom)
        }
        // Again when the material arrives while the page is open (`canWrite`: slides with pages
        // or a transcript) or the recording's state changes (blocked: written from what there is;
        // ready: the replace-once rules caught up); nothing once a version is current and due.
        .task(id: NotesQueueTrigger(lectureID: lectureID, canWrite: page.canWrite, recording: page.recording)) {
            guard queuesOnOpen, let services else { return }
            do {
                try await LectureNotesRepository(store: services.records).queueIfNeeded(lectureID: lectureID)
            } catch {
                CoursesUILog.ui.error("Queueing the lecture's notes failed: \(String(describing: error), privacy: .public)")
            }
        }
        .contentZoomable()
        .onChange(of: page.current?.sections, initial: true) { _, sections in
            state.sections = sections ?? []
        }
        .pane(.yourNotes, identity: lectureID) {
            YourNotesColumn(
                lectureID: lectureID,
                sections: { state.sections },
                follow: { .section(state.readingSection) },
                onEditingChange: { typing in state.typingInColumn = typing }
            )
            .contentZoomable()
        }
    }

    private func content(zoom: CGFloat) -> some View {
        // Before the first measure: the text's measure with its margins.
        let layout = NotesPageLayout(pageWidth: pageWidth > 0 ? pageWidth : 884, zoom: zoom)
        let state = state
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(zoom: zoom)
                    .padding(.horizontal, layout.inset)
                LectureNotesView(
                    lectureID: lectureID, style: .page, layout: layout, writeAgain: { showWriteAgain() },
                    onChatPassage: { passage in
                        if state.chatPassage != passage { state.chatPassage = passage }
                    },
                    onReadingSection: { section in
                        if state.readingSection != section { state.readingSection = section }
                    }
                )
                .padding(.top, 18 * zoom)
                if !page.items.isEmpty {
                    KeepInMindBlock(
                        items: page.items, trails: page.trails, course: page.course, text: SessionText(locale: locale, timeZone: timeZone), zoom: zoom
                    )
                    .padding(.horizontal, layout.inset)
                    .padding(.top, 34 * zoom)
                }
            }
            // Never a fixed width: the measured one must not become the window's minimum (the
            // page could not narrow when a pane opens).
            .frame(minWidth: 0, maxWidth: layout.wide, alignment: .leading)
            .padding(.horizontal, layout.margin)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [isLiveResizing] width in
            guard width > 0 else { return }
            state.measuredWidth = width
            if !isLiveResizing { pageWidth = width }
        }
        .onChange(of: isLiveResizing) { _, resizing in
            // The drag ended: the page takes its width once.
            if !resizing, state.measuredWidth > 0 { pageWidth = state.measuredWidth }
        }
        .background(Color.contentBackground)
        .screenTitle(String(localized: "Lectures"), subtitle: page.course?.name ?? "")
        .transformPreference(AgentContextPreferenceKey.self) { [source = passageContext] value in
            if let source { value = source }
        }
    }

    /// Continue in Chat's passage as the panel's context; `refine` runs once, when a message reads
    /// it: the passage goes with that message only.
    private var passageContext: AgentContextSource? {
        guard let passage = state.chatPassage else { return nil }
        let context = AgentContext(
            screen: .course, courseID: page.lecture?.courseID, courseScreen: "lecture_notes", lectureID: lectureID, notesPassage: passage
        )
        let state = state
        return AgentContextSource(context: context) {
            Task { @MainActor in if state.chatPassage != nil { state.chatPassage = nil } }
            return AgentContext(screen: .course)
        }
    }

    // MARK: Header

    private func header(zoom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * zoom) {
            Text(verbatim: page.lecture?.title.isEmpty == false ? page.lecture?.title ?? "" : String(localized: "Lecture"))
                .font(zoom == 1 ? .title.weight(.semibold) : .system(size: 22 * zoom, weight: .semibold))
                .tracking(-0.3 * zoom)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6 * zoom) {
                meta(zoom: zoom)
                    .font(.system(size: 12 * zoom))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // mt: the course book's chapters this lecture covers ("Ch. 6"), opening the reader.
                if let book = page.book {
                    BookChip(book.label, help: book.help) {
                        openDestination(.material(book.materialID, page: book.page))
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    openDestination(.lecture(lectureID, ReviewTarget()))
                } label: {
                    Text("Open in Review").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // Typing in Your notes or the search field: ↩ is theirs.
                .keyboardShortcut(state.typingInColumn || isSearchFieldFocused ? nil : KeyboardShortcut.defaultAction)
                if studyCoach != nil, page.hasQuestions {
                    Button {
                        practice()
                    } label: {
                        Text("Practice").padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                moreMenu
            }
            // The buttons are chrome: they never zoom.
            .padding(.top, 10)
        }
    }

    private func meta(zoom: CGFloat) -> Text {
        var parts: [Text] = []
        if let number = page.lecture?.number { parts.append(Text("Lecture \(number)")) }
        if let held = page.lecture?.heldAt { parts.append(Text(verbatim: SessionText(locale: locale, timeZone: timeZone).day(held))) }
        if let duration = page.duration, duration > 0 {
            parts.append(Text(verbatim: TimeText.clock(duration)).font(.mono(11.5 * zoom)).monospacedDigit())
        }
        if let range = page.range { parts.append(Text(verbatim: range.pagesText)) }
        var result = Text(verbatim: "")
        for (index, part) in parts.enumerated() {
            result = index == 0 ? part : Text("\(result) · \(part)")
        }
        return result
    }

    /// ⋯: Write Again…, Previous Version, Edit as Note, Copy as Markdown.
    private var moreMenu: some View {
        Menu {
            Button("Write Again…") { showWriteAgain() }
                .disabled(page.current?.state.isOpen == true || !page.canWrite)
            Button("Previous Version") { previousVersion() }
                .disabled(!page.hasPreviousVersion)
            Divider()
            Button("Edit as Note") { editAsNote() }
                .disabled(page.current?.hasText != true || editing)
            Button("Copy as Markdown") {
                if let notes = page.current { Pasteboard.copy(LectureNotesExport.markdown(notes, materials: page.materials)) }
            }
            .disabled(page.current?.hasText != true)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("More"))
        .accessibilityLabel(Text("More"))
        .background {
            Color.clear
                .popover(isPresented: $writeAgainShown, arrowEdge: .bottom) {
                    LectureNotesWriteAgainPopover(request: $request) { sentence in
                        writeAgainShown = false
                        writeAgain(.new(sentence))
                    }
                }
        }
    }

    // MARK: Actions

    private func practice() {
        guard let studyCoach, let courseID = page.lecture?.courseID else { return }
        let scope = StudyScope.lecture(lectureID, course: courseID)
        Task {
            do {
                let session = try await studyCoach.startRound(scope)
                openDestination(.practice(session))
            } catch {
                CoursesUILog.ui.error("Starting a round failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Write Again… from the ⋯ menu or the failure line: the popover with the student's standing
    /// instruction, once the click (or the menu) is done; a version without text has nothing to
    /// refine, so it is queued again at once with that instruction.
    private func showWriteAgain() {
        guard page.current?.hasText == true else {
            writeAgain(.standing)
            return
        }
        request = page.instruction ?? ""
        Task { @MainActor in writeAgainShown = true }
    }

    /// Write Again…: a new version with the student's instruction (Previous Version undoes it),
    /// and what can be re-run of the recording, re-run.
    private func writeAgain(_ instruction: NotesInstruction) {
        guard let services else { return }
        LectureNotesWriteAgain.queue(lectureID: lectureID, instruction: instruction, retry: retry, services: services, undoManager: undoManager)
    }

    /// Previous Version (Edit ▸ Undo "Undo Write Again"; Redo brings the newer one back).
    private func previousVersion() {
        guard let services else { return }
        let repository = LectureNotesRepository(store: services.records)
        let lectureID = lectureID
        let manager = undoManager
        Task {
            guard let taken = try? await repository.previousVersion(lectureID: lectureID) else { return }
            guard let manager else { return }
            let target = WriteAgainUndoTarget()
            manager.registerUndo(withTarget: target) { target in
                Task { try? await repository.restore(taken) }
                manager.registerUndo(withTarget: target) { _ in
                    Task { _ = try? await repository.previousVersion(lectureID: lectureID) }
                }
                manager.setActionName(String(localized: "Previous Version"))
            }
            manager.setActionName(String(localized: "Previous Version"))
        }
    }

    /// Edit as Note: a copy in Notes (the course and lecture set), opened.
    private func editAsNote() {
        guard let services, !editing else { return }
        editing = true
        let lectureID = lectureID
        Task {
            defer { editing = false }
            do {
                guard let note = try await LectureNotesExport.editAsNote(lectureID: lectureID, services: services) else { return }
                if let courseID = note.courseID {
                    openDestination(.notes(.course(courseID), note: note.id))
                } else {
                    openDestination(.notes(.all, note: note.id))
                }
            } catch {
                CoursesUILog.ui.error("Edit as Note failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// The identity Previous Version's undo steps are registered with.
@MainActor
final class WriteAgainUndoTarget {}

/// What the lecture notes page shares with its Your notes pane: the pane is drawn in another
/// hosting view and reads the page only through this object.
@MainActor
@Observable
final class LectureNotesPageState {
    /// The current version's sections (the page's read of `lecture_notes`; the pane reads none).
    var sections: [LectureNotesSection] = []
    /// The section under the notes' reading line (nil: the overview): Your notes marks its groups.
    var readingSection: String?
    /// A note in Your notes has the keyboard: the page's ↩ stands down.
    var typingInColumn = false
    /// Continue in Chat's passage, until a message carries it, a new selection settles or an Ask
    /// starts.
    var chatPassage: NotesPassageContext?
    /// The page's width as last measured, while a drag holds the layout's (not observed: it changes
    /// on every frame of the drag).
    @ObservationIgnored var measuredWidth: CGFloat = 0
}

/// Keep in mind (the brief's third zone, at the end): the lecture's tracked items on one line
/// each: [ring = due, bar = class, filled = done | title with its faint source glyph | day, mono
/// time]; tracked items, never Claude's wording. Its words grow with the content zoom.
private struct KeepInMindBlock: View {
    let items: [TrackedItem]
    let trails: [TrackedItem.ID: [SourceTrailEntry]]
    let course: Course?
    let text: SessionText
    var zoom: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * zoom) {
            Text("Keep in mind")
                .font(zoom == 1 ? .subheadline.weight(.semibold) : .system(size: 11 * zoom, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Hairline().padding(.leading, 22 * zoom)
                    }
                    row(item)
                }
            }
        }
    }

    private func row(_ item: TrackedItem) -> some View {
        let done = item.status == .done
        let color = Color.course(course)
        return HStack(spacing: 12 * zoom) {
            Group {
                if done {
                    Circle().fill(color).frame(width: 10 * zoom, height: 10 * zoom)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 6 * zoom, weight: .heavy)).foregroundStyle(.white))
                } else if item.kind == .announcement {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4 * zoom, height: 18 * zoom)
                } else {
                    DueRing(color: color)
                }
            }
            .frame(width: 10 * zoom)
            HStack(spacing: 6) {
                Text(verbatim: item.title)
                    .font(.system(size: 13 * zoom, weight: done ? .regular : .medium))
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(1)
                SourceTrailButton(entries: trails[item.id] ?? [], now: Date(), inCalendar: item.calendarEventID != nil)
            }
            Spacer(minLength: 8)
            if let due = item.dueAt {
                if item.isAllDay {
                    Text(verbatim: text.day(due))
                } else {
                    Text("\(Text(verbatim: text.day(due))), \(Text(verbatim: DayText.time(due, timeZone: text.timeZone)).font(.mono(11.5 * zoom)).foregroundStyle(.secondary))")
                }
            }
        }
        .font(.system(size: 13 * zoom))
        .foregroundStyle(done ? .secondary : .primary)
        .frame(minHeight: 31 * zoom)
    }
}

/// Reads the content zoom `.contentZoomable()` sets below the page's root.
private struct ZoomReader<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.contentZoom) private var zoom

    var body: some View {
        content(zoom)
    }
}

/// When the page asks for a version (`queueIfNeeded`): on open, and when what it could be written
/// from arrives, or the recording's state changes, while it is open.
struct NotesQueueTrigger: Hashable {
    var lectureID: Lecture.ID
    var canWrite: Bool
    var recording: RecordingNotesState
}

/// The page's rows in one observed read.
struct LectureNotesPageData: Equatable, Sendable {
    var lecture: Lecture?
    var course: Course?
    var duration: Double?
    var range: LectureSlideRange?
    var current: LectureNotes?
    var hasPreviousVersion = false
    /// A new version could be written now (`LectureNotesInputs.available`): Write Again… is off
    /// without it.
    var canWrite = false
    /// The student's standing instruction (`LectureNotes.instruction(of:)`): Write Again…'s
    /// popover opens with it.
    var instruction: String?
    /// How the recording is getting into the Summary.
    var recording: RecordingNotesState = .none
    var hasQuestions = false
    var items: [TrackedItem] = []
    var trails: [TrackedItem.ID: [SourceTrailEntry]] = [:]
    /// mt: the course book's chapters the lecture covers (core coverage), for the meta line's chip.
    var book: LectureBookChip?
    /// mt: the course's materials by key (Copy as Markdown labels `[[mat …]]` chips).
    var materials: [String: NotesMaterialRef] = [:]

    static let empty = LectureNotesPageData()
}

struct LectureNotesPageRequest: FetchKeyRequest {
    let lectureID: Lecture.ID

    func fetch(_ db: Database) throws -> LectureNotesPageData {
        var data = LectureNotesPageData()
        let id = lectureID
        let reference = Lecture.ID?.some(id)
        data.lecture = try Lecture.find(id).fetchOne(db)
        if let courseID = data.lecture?.courseID {
            data.course = try Course.find(courseID).fetchOne(db)
            data.materials = try NotesMaterialRef.load(courseID: courseID, in: db)
            data.book = try LectureBookChip.load(lectureID: id, in: db)
        }
        data.duration = try Recording.where { $0.lectureID.eq(reference) }.order { $0.startedAt.asc() }.fetchOne(db)?.duration
        data.range = try LectureSlides.current(lectureID: id, in: db)
        let versions = try LectureNotesRepository.versions(lectureID: id, in: db)
        let current = LectureNotes.current(of: versions)
        data.current = current
        data.hasPreviousVersion = current.map { current in versions.contains { $0.isCandidate && $0.version < current.version } } ?? false
        let inputs = try LectureNotesRepository.inputs(lectureID: id, in: db)
        data.canWrite = inputs.available != nil
        data.recording = inputs.recording
        data.instruction = LectureNotes.instruction(of: versions)
        data.hasQuestions = try StudyQuestion.where { $0.lectureID.eq(reference) && $0.retiredAt.is(nil) }.fetchCount(db) > 0
            || current?.sections.contains { !$0.questionIDs.isEmpty } == true
        // Keep in mind: what was said in this lecture and tracked (deadlines, room changes, tasks).
        let sources = try TrackedItemSource.where { $0.lectureID.eq(reference) && $0.undoneAt.is(nil) }.fetchAll(db)
        let itemIDs = Array(Set(sources.map(\.trackedItemID)))
        if !itemIDs.isEmpty {
            data.items = try TrackedItem.where { $0.id.in(itemIDs) && $0.status.neq(TrackedItemStatus.dismissed) }.fetchAll(db)
                .sorted { ($0.dueAt ?? .distantFuture, $0.title) < ($1.dueAt ?? .distantFuture, $1.title) }
            data.trails = try TrackedItemRepository.trails(itemIDs: data.items.map(\.id), in: db)
        }
        return data
    }
}

/// The meta line's book chip (mt, docs/plan-materials.md §2.5): "Ch. 6" or "Ch. 6, 7", the course
/// book's chapters the lecture covers (a core section of them, `MaterialCoverage.effective`); its
/// help the book's title and the chapters with their printed first pages; a click opens the
/// reader at the first chapter.
struct LectureBookChip: Equatable, Sendable {
    var materialID: CourseMaterial.ID
    var label: String
    var help: String
    /// The first chapter's first PDF page.
    var page: Int

    static func load(lectureID: Lecture.ID, in db: Database) throws -> LectureBookChip? {
        let covered = MaterialCoverage.effective(try MaterialCoverage.where { $0.lectureID.eq(lectureID) }.fetchAll(db))
            .filter { $0.strength == .core }
        guard !covered.isEmpty else { return nil }
        let materialIDs = Array(Set(covered.map(\.materialID)))
        let found: [CourseMaterial] = try CourseMaterial.where { $0.id.in(materialIDs) }.fetchAll(db)
        let books = found.filter { material in material.kind == MaterialKind.book && material.state == MaterialState.ready }
        guard let book = books.sorted(by: CourseMaterial.shelfOrder).first else { return nil }
        let bookID = book.id
        let sections: [MaterialSection] = try MaterialSection.where { $0.materialID.eq(bookID) }.fetchAll(db)
        var byID: [MaterialSection.ID: MaterialSection] = [:]
        for section in sections { byID[section.id] = section }
        var chapters: [MaterialSection] = []
        for row in covered where row.materialID == book.id {
            guard let chapter = byID[row.sectionID]?.chapter(in: sections), !chapter.number.isEmpty,
                  !chapters.contains(where: { $0.id == chapter.id }) else { continue }
            chapters.append(chapter)
        }
        chapters.sort { $0.firstPage < $1.firstPage }
        guard let first = chapters.first else { return nil }
        let lines = chapters.map { chapter in
            "\(chapter.number) \(chapter.title)" + (chapter.printedFirst.map { " · p. \($0)" } ?? "")
        }
        return LectureBookChip(
            materialID: book.id, label: MaterialText.chapters(chapters.map(\.number)),
            help: ([book.title] + lines).joined(separator: "\n"), page: first.firstPage
        )
    }
}
#endif

/// The mini determinate ring of a lecture whose notes are being written (`.sig .pr`): accent on
/// the fill-2 track, 12 pt.
struct NotesProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(.fill.secondary, lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: value)
                .stroke(.tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(Text("Writing"))
        .accessibilityValue(Text(verbatim: "\(Int(value * 100)) %"))
    }
}
