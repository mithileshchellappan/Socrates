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
/// click; a version without text is queued again at once. It is off while a version is open or
/// nothing could be written (no slides with pages, no transcript).
///
/// nl: the page grows with the window (`NotesPageLayout`): the text at most 780 pt, code, tables,
/// diagrams, charts and slides breaking out to at most 1120, the header and Keep in mind at the
/// text's measure; 52 pt margins (22 under 640 pt of page). Your notes (`YourNotesColumn`) is the
/// window's inspector column beside it: open by default from 1160 pt of detail width, closed
/// under 1120, unchanged between; the student's toggle (the toolbar's Show Inspector while closed,
/// the column header's Hide, ⌃⌘I / View ▸ Show Inspector) is kept per window; the expanded agent
/// panel takes its place. While a note in the column is being typed in, ↩ (Open in Review) and the
/// notes' ⌘K / ⇧⌘E stand down. View ▸ Zoom In / Out scale the content (title, meta, notes, Keep in
/// mind, the column's notes), never the buttons.
///
/// The expanded agent panel's coming and going builds the page under the inspector again (DESIGN
/// 6.4: the column is left out, not hidden), so what must survive it lives here, above that
/// branch: the scroll offset (put back once the text is long enough again, as Calendar does) and
/// Continue in Chat's passage (the page publishes it: the notes view hands it up).
public struct LectureNotesPage: View {
    /// Your notes opens by itself from this detail width, and closes under `closesBelow`.
    static let opensFrom: CGFloat = 1160
    static let closesBelow: CGFloat = 1120
    /// The screen's declared minimum width (DESIGN 3.3): the page and the open column together.
    static let screenMinimum: CGFloat = 480

    private let lectureID: Lecture.ID
    @Fetch private var page: LectureNotesPageData
    @State private var writeAgainShown = false
    @State private var request = ""
    @State private var editing = false
    /// C: the page's width (the detail column less Your notes while it is open).
    @State private var pageWidth: CGFloat = 0
    @State private var columnWidth: CGFloat = 336
    /// `auto`'s state: open or closed by the detail width.
    @State private var opensByWidth = LectureNotesPage.lastOpensByWidth
    @State private var readingSection: String?
    /// A note in Your notes has focus.
    @State private var typingInColumn = false
    @State private var kept = LectureNotesPageState()
    @State private var scroll = ScrollPosition(edge: .top)
    /// The page has been scrolled back to `kept.offset` in its layout with the agent panel
    /// expanded (true) or not (false); nil: not yet.
    @State private var openedFor: Bool?
    @SceneStorage(YourNotesVisibility.sceneStorageKey) private var storedVisibility = YourNotesVisibility.auto.rawValue
    @Environment(\.studyServices) private var services
    @Environment(\.openDestination) private var openDestination
    @Environment(\.studyCoach) private var studyCoach
    @Environment(\.undoManager) private var undoManager
    @Environment(\.lectureNotesQueuesOnOpen) private var queuesOnOpen
    @Environment(\.yourNotesVisibilityOverride) private var visibilityOverride
    @Environment(\.agentPanelExpanded) private var agentPanelExpanded
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    public init(lectureID: Lecture.ID) {
        self.lectureID = lectureID
        _page = Fetch(wrappedValue: .empty, LectureNotesPageRequest(lectureID: lectureID))
    }

    public var body: some View {
        ZoomReader { zoom in
            content(zoom: zoom)
        }
        // Again when the material arrives while the page is open (`canWrite`: slides with pages
        // or a transcript); it queues nothing once a version is current.
        .task(id: NotesQueueTrigger(lectureID: lectureID, canWrite: page.canWrite)) {
            guard queuesOnOpen, let services else { return }
            do {
                try await LectureNotesRepository(store: services.records).queueIfNeeded(lectureID: lectureID)
            } catch {
                CoursesUILog.ui.error("Queueing the lecture's notes failed: \(String(describing: error), privacy: .public)")
            }
        }
        .contentZoomable()
    }

    private func content(zoom: CGFloat) -> some View {
        // Before the first measure: the text's measure with its margins.
        let layout = NotesPageLayout(pageWidth: pageWidth > 0 ? pageWidth : 884, zoom: zoom)
        // Not a scroll view at the top edge: one there runs under the toolbar, and the window then
        // draws Your notes as floating glass over the page (as a sidebar) instead of the inspector
        // column Review and Calendar have.
        return VStack(spacing: 0) {
            Color.contentBackground.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(zoom: zoom)
                        .padding(.horizontal, layout.inset)
                    LectureNotesView(
                        lectureID: lectureID, style: .page, layout: layout, writeAgain: { showWriteAgain() },
                        onChatPassage: { [kept] passage in
                            if kept.chatPassage != passage { kept.chatPassage = passage }
                        },
                        onReadingSection: { section in
                            if readingSection != section { readingSection = section }
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
                // page could not narrow when Your notes opens).
                .frame(minWidth: 0, maxWidth: layout.wide, alignment: .leading)
                .padding(.horizontal, layout.margin)
                .padding(.top, 26)
                .padding(.bottom, 40)
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height - $0.containerSize.height } action: { [expanded = agentPanelExpanded] _, reach in
                restoreOffset(reach: reach, expanded: expanded)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { [expanded = agentPanelExpanded, kept] _, y in
                // Kept without re-rendering the page (not observed); only once this scroll view
                // has been put back (a new one starts at the top).
                guard openedFor == expanded else { return }
                kept.offset = y
            }
            .onScrollPhaseChange { [expanded = agentPanelExpanded] _, phase in
                // The student scrolls before the text is long enough again: where they go wins.
                if openedFor != expanded, phase == .tracking || phase == .interacting { openedFor = expanded }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard width > 0 else { return }
            pageWidth = width
            followWidth()
        }
        .background(Color.contentBackground)
        // The title and toolbar before the inspector, as Review and Calendar have them.
        .screenTitle(String(localized: "Lectures"), subtitle: page.course?.name ?? "")
        .toolbar {
            // Exactly one inspector toggle: this one while the column is closed (DESIGN 6.4).
            if !isColumnShown, !agentPanelExpanded {
                ToolbarItem(placement: .primaryAction) {
                    Button("Show Inspector", systemImage: "sidebar.trailing") { setColumn(shown: true) }
                        .help(Text("Show Inspector"))
                }
            }
        }
        .modifier(YourNotesInspector(isPanelExpanded: agentPanelExpanded, isPresented: columnBinding) {
            YourNotesColumn(
                lectureID: lectureID, sections: page.current?.sections ?? [], readingSection: readingSection, isShown: isColumnShown && !agentPanelExpanded,
                hide: { setColumn(shown: false) },
                onEditingChange: { typing in typingInColumn = typing }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                // A hidden column can report nothing; its minimum is 260.
                guard width >= 200 else { return }
                columnWidth = width
                followWidth()
            }
            // Outermost: under the geometry reader the column took its content's width as both its
            // minimum and maximum (270 pt).
            .inspectorColumnWidth(min: 260, ideal: 336, max: 440)
        })
        // Outside the branch above, so a rebuilt notes view does not lose it.
        .transformPreference(AgentContextPreferenceKey.self) { [source = passageContext] value in
            if let source { value = source }
        }
    }

    // MARK: Kept across the agent panel

    /// The page laid out again (the agent panel took or gave back the column's place): back to
    /// where it was, as far as the text reaches yet (it grows from its placeholder height), until
    /// it reaches that far.
    private func restoreOffset(reach: CGFloat, expanded: Bool) {
        guard openedFor != expanded else { return }
        let y = kept.offset
        guard y > 0 else {
            openedFor = expanded
            return
        }
        guard reach > 0 else { return }
        scroll.scrollTo(y: min(y, reach))
        if reach >= y { openedFor = expanded }
    }

    /// Continue in Chat's passage as the panel's context; `refine` runs once, when a message reads
    /// it: the passage goes with that message only.
    private var passageContext: AgentContextSource? {
        guard let passage = kept.chatPassage else { return nil }
        let context = AgentContext(
            screen: .course, courseID: page.lecture?.courseID, courseScreen: "lecture_notes", lectureID: lectureID, notesPassage: passage
        )
        let kept = kept
        return AgentContextSource(context: context) {
            Task { @MainActor in if kept.chatPassage != nil { kept.chatPassage = nil } }
            return AgentContext(screen: .course)
        }
    }

    // MARK: Your notes

    private var visibility: YourNotesVisibility {
        visibilityOverride ?? YourNotesVisibility(rawValue: storedVisibility) ?? .auto
    }

    private var isColumnShown: Bool {
        switch visibility {
        case .auto: opensByWidth
        case .shown: true
        case .hidden: false
        }
    }

    /// The inspector's binding: ⌃⌘I, the header's Hide, dragging the column shut. Off while the
    /// expanded agent panel has the column's place.
    private var columnBinding: Binding<Bool> {
        let shown = isColumnShown
        let expanded = agentPanelExpanded
        return Binding(
            get: { shown && !expanded },
            set: { value in
                guard !expanded, value != shown else { return }
                setColumn(shown: value)
            }
        )
    }

    /// The student's toggle: kept for the window, every lecture page.
    private func setColumn(shown: Bool) {
        storedVisibility = (shown ? YourNotesVisibility.shown : .hidden).rawValue
    }

    /// `auto`: open from 1160 pt of detail width (D: the page and the open column), closed under
    /// 1120, unchanged between (a resize near the line never flips it). Not while the agent panel
    /// has the column's place: it comes back as it was.
    private func followWidth() {
        // A page narrower than a laid-out window ever gives it (the screen is at least 480 pt,
        // the open column included) is a pass before the window has its size: it must not close
        // the column (presented again a moment later, the column came back at its 260 pt minimum).
        let narrowest = max(40, Self.screenMinimum - (isColumnShown ? columnWidth : 0))
        guard !agentPanelExpanded, pageWidth >= narrowest else { return }
        let detail = pageWidth + (isColumnShown ? columnWidth : 0)
        let opens = detail >= Self.opensFrom ? true : detail < Self.closesBelow ? false : opensByWidth
        Self.lastOpensByWidth = opens
        guard opens != opensByWidth else { return }
        // The window's width decides, not the student: no slide in or out.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { opensByWidth = opens }
    }

    /// `auto`'s last decision in this run: the next lecture page opens with its column as the
    /// last one had it (the window is usually as wide), so the column is there from the page's
    /// first frame rather than sliding in after the first measure. Open at first (wide windows).
    @MainActor private static var lastOpensByWidth = true

    // MARK: Header

    private func header(zoom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * zoom) {
            Text(verbatim: page.lecture?.title.isEmpty == false ? page.lecture?.title ?? "" : String(localized: "Lecture"))
                .font(zoom == 1 ? .title.weight(.semibold) : .system(size: 22 * zoom, weight: .semibold))
                .tracking(-0.3 * zoom)
                .fixedSize(horizontal: false, vertical: true)
            meta(zoom: zoom)
                .font(.system(size: 12 * zoom))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Button {
                    openDestination(.lecture(lectureID, ReviewTarget()))
                } label: {
                    Text("Open in Review").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // Typing in Your notes: ↩ is the note's.
                .keyboardShortcut(typingInColumn ? nil : KeyboardShortcut.defaultAction)
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
                if let notes = page.current { Pasteboard.copy(LectureNotesExport.markdown(notes)) }
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
                        writeAgain(sentence)
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

    /// Write Again… from the ⋯ menu or the failure line: the popover, once the click (or the menu)
    /// is done; a version without text has nothing to refine, so it is queued again at once.
    private func showWriteAgain() {
        guard page.current?.hasText == true else {
            writeAgain("")
            return
        }
        Task { @MainActor in writeAgainShown = true }
    }

    /// Write Again…: a new version with the student's sentence (Previous Version undoes it).
    private func writeAgain(_ sentence: String) {
        guard let services else { return }
        request = ""
        LectureNotesWriteAgain.queue(lectureID: lectureID, request: sentence, services: services, undoManager: undoManager)
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

/// What the lecture notes page keeps across the notes view being built again.
@MainActor
@Observable
final class LectureNotesPageState {
    /// Continue in Chat's passage, until a message carries it, a new selection settles or an Ask
    /// starts.
    var chatPassage: NotesPassageContext?
    /// Where the page is scrolled to: not observed (it changes with every scrolled point).
    @ObservationIgnored var offset: CGFloat = 0
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

/// Your notes, left out entirely while the agent panel is expanded into the window's trailing
/// column (DESIGN 6.4: never two inspectors; a hidden inspector still kept its column's room).
private struct YourNotesInspector<Column: View>: ViewModifier {
    let isPanelExpanded: Bool
    let isPresented: Binding<Bool>
    @ViewBuilder let column: () -> Column

    func body(content: Content) -> some View {
        if isPanelExpanded {
            content
        } else {
            content.inspector(isPresented: isPresented, content: column)
        }
    }
}

/// When the page asks for its first version (`queueIfNeeded`): on open, and when what it could be
/// written from arrives while it is open.
struct NotesQueueTrigger: Hashable {
    var lectureID: Lecture.ID
    var canWrite: Bool
}

/// The page's rows in one observed read.
struct LectureNotesPageData: Equatable, Sendable {
    var lecture: Lecture?
    var course: Course?
    var duration: Double?
    var range: LectureSlideRange?
    var current: LectureNotes?
    var hasPreviousVersion = false
    /// A new version could be written now (`LectureNotesRepository.source`): Write Again… is off
    /// without it.
    var canWrite = false
    var hasQuestions = false
    var items: [TrackedItem] = []
    var trails: [TrackedItem.ID: [SourceTrailEntry]] = [:]

    static let empty = LectureNotesPageData()
}

struct LectureNotesPageRequest: FetchKeyRequest {
    let lectureID: Lecture.ID

    func fetch(_ db: Database) throws -> LectureNotesPageData {
        var data = LectureNotesPageData()
        let id = lectureID
        let reference = Lecture.ID?.some(id)
        data.lecture = try Lecture.find(id).fetchOne(db)
        if let courseID = data.lecture?.courseID { data.course = try Course.find(courseID).fetchOne(db) }
        data.duration = try Recording.where { $0.lectureID.eq(reference) }.order { $0.startedAt.asc() }.fetchOne(db)?.duration
        data.range = try LectureSlides.current(lectureID: id, in: db)
        let versions = try LectureNotesRepository.versions(lectureID: id, in: db)
        let current = LectureNotes.current(of: versions)
        data.current = current
        data.hasPreviousVersion = current.map { current in versions.contains { $0.isCandidate && $0.version < current.version } } ?? false
        data.canWrite = try LectureNotesRepository.source(lectureID: id, in: db) != nil
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
