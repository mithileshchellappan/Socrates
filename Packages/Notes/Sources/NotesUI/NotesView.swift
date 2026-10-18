import Notes
import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

/// The Notes screen (mockup 04, DESIGN 8.4): the note list column (236 pt) | `Divider` | the
/// editor, for All Notes or one course. The app passes the selection (kept per window, set by
/// `StudyDestination.notes(_, note:)`) and the toolbar search field's text, which filters the list
/// in place ("Search notes").
///
/// Toolbar: leading New Note; trailing [Aa ⌄, checklist, image, sketch] [Slide, Quote]. Like
/// Apple Notes the screen opens on its newest note when nothing is selected; New Note starts an
/// empty note in Title that becomes a row on its first keystroke. Delete Note (⌫ in the list, the
/// row's menu) has Undo; Move To files a note under another course or lecture.
public struct NotesView: View {
    private let scope: NotesScope
    @Binding private var selection: Note.ID?
    private let query: String

    private let notesQuery: FetchAll<Note>
    private let coursesQuery: FetchAll<Course>
    private let lecturesQuery: FetchAll<Lecture>

    @Environment(\.studyServices) private var services
    @Environment(\.undoManager) private var undoManager
    @State private var session: NoteSession?
    @State private var pending: PendingNote?
    @State private var controller = NoteEditorController()
    @State private var focusRequest = 0
    @State private var showsImageImporter = false
    @State private var showsSlides = false
    @State private var showsQuotes = false
    @State private var showsStyles = false
    @State private var undoTarget = NotesUndoTarget()
    @FocusState private var listFocused: Bool

    /// The list column's width (DESIGN 3.3).
    static let listWidth: CGFloat = 236

    public init(scope: NotesScope, selection: Binding<Note.ID?>, query: String = "") {
        self.scope = scope
        _selection = selection
        self.query = query
        switch scope {
        case .all:
            notesQuery = FetchAll(Note.order { $0.updatedAt.desc() })
        case .course(let id):
            notesQuery = FetchAll(Note.where { $0.courseID.eq(id) }.order { $0.updatedAt.desc() })
        }
        coursesQuery = FetchAll(Course.order(by: \.sortOrder))
        lecturesQuery = FetchAll(Lecture.order(by: \.createdAt))
    }

    // MARK: Data

    private var notes: [Note] { notesQuery.wrappedValue }
    private var courses: [Course] { coursesQuery.wrappedValue }
    private var lectures: [Lecture] { lecturesQuery.wrappedValue }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var items: [NoteListItem] {
        let courseByID = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lectureByID = Dictionary(lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items = NoteList.items(notes, courses: courseByID, lectures: lectureByID, query: trimmedQuery)
        // The new note before its first keystroke (selected, at the top).
        if let pending, selection == pending.id, !items.contains(where: { $0.id == pending.id }), !notes.contains(where: { $0.id == pending.id }), trimmedQuery.isEmpty {
            let note = Note(id: pending.id, courseID: pending.courseID, lectureID: pending.lectureID, createdAt: pending.createdAt, updatedAt: pending.createdAt)
            items.insert(NoteListItem(note: note, name: String(localized: "New Note"), preview: ""), at: 0)
        }
        return items
    }

    private var sections: [NoteListSection] {
        switch scope {
        case .all: NoteList.sections(items, courses: courses)
        case .course: [NoteListSection(course: nil, items: items)]
        }
    }

    private var selectedNote: Note? {
        guard let selection else { return nil }
        return notes.first { $0.id == selection }
    }

    private var scopeCourseID: Course.ID? {
        if case .course(let id) = scope { return id }
        return nil
    }

    /// The open note's course (a new one: the course it is made in).
    private var editingCourseID: Course.ID? {
        session?.note?.courseID ?? selectedNote?.courseID ?? (pending?.id == selection ? pending?.courseID : nil)
    }

    private var editingLectureID: Lecture.ID? {
        session?.note?.lectureID ?? selectedNote?.lectureID ?? (pending?.id == selection ? pending?.lectureID : nil)
    }

    private var editingCourse: Course? {
        editingCourseID.flatMap { id in courses.first { $0.id == id } }
    }

    // MARK: Body

    public var body: some View {
        Group {
            if notes.isEmpty, pending == nil {
                ContentUnavailableView {
                    Image(systemName: "doc.text")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    listColumn
                        .frame(width: Self.listWidth)
                    Divider()
                    editor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.contentBackground)
        .toolbar { toolbar }
        .fileImporter(isPresented: $showsImageImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { controller.insertImages(at: urls) }
        }
        .onAppear {
            selectFirstIfNeeded()
            openSession(for: selection)
        }
        .onChange(of: selection) { _, id in openSession(for: id) }
        .onChange(of: notes.map(\.id)) {
            if session == nil { openSession(for: selection) }
            selectFirstIfNeeded()
        }
        .onDisappear {
            if let session { Task { await session.flush() } }
            NoteImageCache.removeAll()
            NoteDeckCache.removeAll()
        }
    }

    // MARK: List

    private var listColumn: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(sections) { section in
                    if let course = section.course, case .all = scope {
                        Section {
                            rows(section.items)
                        } header: {
                            NoteGroupHeader(course: course)
                        }
                        .listSectionSeparator(.hidden)
                    } else {
                        rows(section.items)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .contextMenu(forSelectionType: Note.ID.self) { ids in
                menu(for: ids)
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard let selection, notes.contains(where: { $0.id == selection }) else { return .ignored }
                delete(selection)
                return .handled
            }
            .onAppear { scrollTo(selection, proxy: proxy) }
            .onChange(of: selection) { _, id in scrollTo(id, proxy: proxy) }
            .overlay {
                if !trimmedQuery.isEmpty, items.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
        }
    }

    private func rows(_ items: [NoteListItem]) -> some View {
        ForEach(items) { item in
            NoteListRow(item: item)
                .tag(item.id)
                .id(item.id)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                // Mockup 04: rows and groups without separators.
                .listRowSeparator(.hidden)
        }
    }

    private func scrollTo(_ id: Note.ID?, proxy: ScrollViewProxy) {
        guard let id, items.contains(where: { $0.id == id }) else { return }
        proxy.scrollTo(id)
    }

    @ViewBuilder
    private func menu(for ids: Set<Note.ID>) -> some View {
        let existing = ids.filter { id in notes.contains { $0.id == id } }
        if !existing.isEmpty {
            Menu("Move To") {
                ForEach(courses) { course in
                    Menu(course.name) {
                        Button(course.name) { move(existing, courseID: course.id, lectureID: nil) }
                        let own = lectures.filter { $0.courseID == course.id }.sorted(by: lectureOrder)
                        if !own.isEmpty { Divider() }
                        ForEach(own) { lecture in
                            Button(lectureLabel(lecture)) { move(existing, courseID: course.id, lectureID: lecture.id) }
                        }
                    }
                }
            }
            Divider()
            Button("Delete") {
                for id in existing { delete(id) }
            }
        }
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let session {
            NoteEditor(
                session: session,
                style: .document,
                startsWith: session.isNew ? .title : .body,
                controller: controller,
                professor: professorName(editingCourse),
                lectureID: editingLectureID,
                focusRequest: focusRequest,
                startsFocused: session.isNew
            )
            .id(session.id)
        } else {
            Color.clear
        }
    }

    private func professorName(_ course: Course?) -> String? {
        guard let professor = course?.professors.first else { return nil }
        return String(localized: "Prof. \(SourceTrailText.surname(professor))")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: newNote) {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .help(Text("New Note"))
        }
        // The editing groups in the toolbar's middle (mockup 04): the window's search field takes the
        // trailing end, and items of the app's outer toolbar come before a screen's own primary
        // actions, so these could not follow it there.
        ToolbarItemGroup(placement: .principal) {
            // Aa ⌄: a popover of the paragraph styles, as in Notes (a toolbar Menu would leave the
            // group's glass).
            Button {
                showsStyles = true
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: "Aa")
                        .font(.system(size: 13.5, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Paragraph Style"))
            }
            .help(Text("Paragraph Style"))
            .disabled(session == nil)
            .popover(isPresented: $showsStyles, arrowEdge: .bottom) {
                NoteStylePicker(current: controller.paragraphKind) { kind in
                    showsStyles = false
                    controller.apply(kind)
                }
            }
            Button {
                controller.apply(.checklist)
            } label: {
                Label("Checklist", systemImage: "checklist")
            }
            .help(Text("Checklist"))
            .disabled(session == nil)
            Button {
                showsImageImporter = true
            } label: {
                Label("Image", systemImage: "photo")
            }
            .help(Text("Image"))
            .disabled(session == nil)
            Button {
                controller.insertSketch()
            } label: {
                Label("Sketch", systemImage: "pencil")
            }
            .help(Text("Sketch"))
            .disabled(session == nil)
        }
        ToolbarSpacer(.fixed, placement: .principal)
        ToolbarItemGroup(placement: .principal) {
            Button {
                showsSlides = true
            } label: {
                Label("Slide", systemImage: "display")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(session == nil || (editingCourseID == nil && editingLectureID == nil))
            .popover(isPresented: $showsSlides, arrowEdge: .bottom) {
                NoteSlidePicker(courseID: editingCourseID, lectureID: editingLectureID) { inline in
                    showsSlides = false
                    controller.insertSlideClip(inline)
                }
            }
            Button {
                showsQuotes = true
            } label: {
                Label("Quote", systemImage: "waveform")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(session == nil || (editingCourseID == nil && editingLectureID == nil))
            .popover(isPresented: $showsQuotes, arrowEdge: .bottom) {
                NoteQuotePicker(courseID: editingCourseID, lectureID: editingLectureID) { block in
                    showsQuotes = false
                    controller.insertQuote(block)
                }
            }
        }
    }

    // MARK: Actions

    /// Like Apple Notes: with nothing selected (or a note of another course), the newest note is open.
    private func selectFirstIfNeeded() {
        guard trimmedQuery.isEmpty, let first = sections.first?.items.first else { return }
        if let selection {
            // The open note stays open even while it has no row (emptied out, deleted on save).
            guard !notes.contains(where: { $0.id == selection }), pending?.id != selection, session?.id != selection else { return }
        }
        selection = first.id
    }

    /// The editor's session for the selected note (the previous one is saved first).
    private func openSession(for id: Note.ID?) {
        if let old = session, old.id != id {
            Task { await old.flush() }
        }
        guard let id, let services else {
            session = nil
            return
        }
        if session?.id == id { return }
        if let note = notes.first(where: { $0.id == id }) {
            session = NoteSession(note: note, store: services.records)
        } else if let pending, pending.id == id {
            session = NoteSession(id: id, store: services.records) { id in
                Note(id: id, courseID: pending.courseID, lectureID: pending.lectureID)
            }
        } else {
            session = nil
        }
    }

    /// New Note: an empty note in Title, in the scope's course (All Notes: the selected note's).
    private func newNote() {
        let courseID = scopeCourseID ?? selectedNote?.courseID
        let note = PendingNote(courseID: courseID, lectureID: nil)
        pending = note
        selection = note.id
        focusRequest += 1
    }

    private func delete(_ id: Note.ID) {
        guard let services, let note = notes.first(where: { $0.id == id }) else { return }
        if session?.id == id {
            session?.discard()
            session = nil
        }
        if selection == id {
            let ordered = sections.flatMap(\.items).map(\.id)
            let index = ordered.firstIndex(of: id)
            let next = index.flatMap { ordered.indices.contains($0 + 1) ? ordered[$0 + 1] : ($0 > 0 ? ordered[$0 - 1] : nil) }
            selection = next
        }
        Task {
            do {
                try await services.records.delete(Note.self, id: id)
            } catch {
                NotesLog.logger.error("Deleting a note failed: \(String(describing: error), privacy: .public)")
            }
        }
        NotesUndo.registerDelete(undoManager, target: undoTarget, note: note, services: services, selection: $selection)
    }

    private func move(_ ids: Set<Note.ID>, courseID: Course.ID, lectureID: Lecture.ID?) {
        guard let services else { return }
        Task {
            do {
                try await services.database.write { db in
                    for id in ids {
                        guard let note = try Note.find(id).fetchOne(db) else { continue }
                        // Review finds a slide's notes by lecture + page, so a slide note keeps its
                        // anchor only in a lecture that shows its deck; elsewhere it becomes a
                        // lecture (or course) note. The recording belongs to the old lecture.
                        let lectureChanged = lectureID != note.lectureID
                        var dropsSlide = note.pageNumber != nil && lectureChanged
                        if dropsSlide, let lectureID, let deckID = note.deckID {
                            dropsSlide = try LectureDeckSpan
                                .where { $0.lectureID.eq(lectureID) && $0.deckID.eq(deckID) }
                                .fetchCount(db) == 0
                        }
                        try Note.find(id).update {
                            $0.courseID = Course.ID?.some(courseID)
                            $0.lectureID = lectureID
                            if dropsSlide {
                                $0.pageNumber = Int?.none
                                $0.deckID = Deck.ID?.none
                            }
                            if lectureChanged {
                                $0.recordingID = Recording.ID?.none
                                $0.audioTime = Double?.none
                            }
                        }
                        .execute(db)
                    }
                }
            } catch {
                NotesLog.logger.error("Moving a note failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func lectureOrder(_ lhs: Lecture, _ rhs: Lecture) -> Bool {
        (lhs.number ?? Int.max, lhs.heldAt ?? .distantFuture) < (rhs.number ?? Int.max, rhs.heldAt ?? .distantFuture)
    }

    private func lectureLabel(_ lecture: Lecture) -> String {
        let number = lecture.number.map { "L\($0)" }
        return [number, lecture.title.isEmpty ? nil : lecture.title].compactMap(\.self).joined(separator: " · ")
    }
}

/// A note made with New Note that has no row until its first keystroke.
private struct PendingNote: Equatable {
    let id = UUID()
    let courseID: Course.ID?
    let lectureID: Lecture.ID?
    let createdAt = Date()
}

/// One row (mockup 04): the name 13 semibold; the time (12 medium, primary; SF Mono for a clock)
/// and the preview (12 secondary) on one line.
struct NoteListRow: View {
    let item: NoteListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: item.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                NoteTimeText(time: NoteListTime(item.note.updatedAt))
                Text(verbatim: item.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

struct NoteTimeText: View {
    let time: NoteListTime

    var body: some View {
        switch time {
        case .clock(let date):
            Text(verbatim: DayText.time(date))
                .font(.mono(12, weight: .medium))
                .monospacedDigit()
        case .yesterday:
            Text("Yesterday")
                .font(.system(size: 12, weight: .medium))
        case .weekday(let date):
            Text(date, format: .dateTime.weekday(.wide))
                .font(.system(size: 12, weight: .medium))
        case .day(let date):
            Text(verbatim: DayText.day(date))
                .font(.system(size: 12, weight: .medium))
        }
    }
}

/// Aa's popover: Title, Heading, Subheading, Body, each in its own type; the current one checked.
struct NoteStylePicker: View {
    let current: NoteParagraphKind
    let pick: (NoteParagraphKind) -> Void

    var body: some View {
        let metrics = NoteMetrics(style: .document)
        VStack(alignment: .leading, spacing: 0) {
            ForEach([NoteParagraphKind.title, .heading, .subheading, .body], id: \.self) { kind in
                Button {
                    pick(kind)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(kind == current ? 1 : 0)
                        Text(kind.label)
                            .font(font(kind, metrics: metrics))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 200)
    }

    private func font(_ kind: NoteParagraphKind, metrics: NoteMetrics) -> Font {
        switch kind {
        case .title: .system(size: metrics.headingSize(1), weight: .bold)
        case .heading: .system(size: metrics.headingSize(2), weight: .semibold)
        case .subheading: .system(size: metrics.headingSize(3), weight: .semibold)
        default: .system(size: metrics.bodySize)
        }
    }
}

/// All Notes' course header: dot + name, subheadline semibold secondary, no count.
struct NoteGroupHeader: View {
    let course: Course

    var body: some View {
        HStack(spacing: 7) {
            CourseDot(course: course, size: 8)
            Text(verbatim: course.name)
                .lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }
}

/// The identity Delete Note's undo steps are registered with.
@MainActor
final class NotesUndoTarget {}

@MainActor
enum NotesUndo {
    /// Undo puts the note back (with its own dates) and selects it; redo deletes it again.
    static func registerDelete(_ manager: UndoManager?, target: NotesUndoTarget, note: Note, services: StudyServices, selection: Binding<Note.ID?>) {
        guard let manager else { return }
        manager.registerUndo(withTarget: target) { target in
            Task {
                do {
                    try await services.database.write { db in
                        try Note.upsert { note }.execute(db)
                    }
                    selection.wrappedValue = note.id
                } catch {
                    NotesLog.logger.error("Restoring a note failed: \(String(describing: error), privacy: .public)")
                }
            }
            manager.registerUndo(withTarget: target) { target in
                Task { try? await services.records.delete(Note.self, id: note.id) }
                registerDelete(manager, target: target, note: note, services: services, selection: selection)
            }
            manager.setActionName(String(localized: "Delete Note"))
        }
        manager.setActionName(String(localized: "Delete Note"))
    }
}
