import SwiftUI
#if os(macOS)
import Courses
import StudyCore
import StudyPageUI
import StudyUI

/// A lecture's notes, pushed full width on its course's Lectures (ln, docs/plan-lecture-notes.md
/// "Build plan", decision 1; mockups 30–33): the reading column centred, at most 680 pt of text.
/// Three zones: the header (title; "Lecture 3 · Mon 19 Oct · 1:29:36 · slides 1–42"; [Open in
/// Review] filled, [Practice], ⋯ with Write Again…, Previous Version, Edit as Note, Copy as
/// Markdown), the notes (`LectureNotesView`), Keep in mind (the lecture's tracked items) at the
/// end. The first open of a lecture without notes queues them (`queueIfNeeded`), except where
/// `\.lectureNotesQueuesOnOpen` is off (renders). Write Again… (the ⋯ menu, the failure line) opens
/// its popover hung off a plain view behind the ⋯ (a popover on the `Menu` itself does not show
/// reliably), after the click; a version without text is queued again at once. It is off while a
/// version is open or nothing could be written (no slides with pages, no transcript).
public struct LectureNotesPage: View {
    private let lectureID: Lecture.ID
    @Fetch private var page: LectureNotesPageData
    @State private var writeAgainShown = false
    @State private var request = ""
    @State private var editing = false
    @Environment(\.studyServices) private var services
    @Environment(\.openDestination) private var openDestination
    @Environment(\.studyCoach) private var studyCoach
    @Environment(\.undoManager) private var undoManager
    @Environment(\.lectureNotesQueuesOnOpen) private var queuesOnOpen
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    public init(lectureID: Lecture.ID) {
        self.lectureID = lectureID
        _page = Fetch(wrappedValue: .empty, LectureNotesPageRequest(lectureID: lectureID))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                LectureNotesView(lectureID: lectureID, style: .page, writeAgain: { showWriteAgain() })
                    .padding(.top, 18)
                if !page.items.isEmpty {
                    KeepInMindBlock(items: page.items, trails: page.trails, course: page.course, text: SessionText(locale: locale, timeZone: timeZone))
                        .padding(.top, 34)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Color.contentBackground)
        .screenTitle(String(localized: "Lectures"), subtitle: page.course?.name ?? "")
        .task(id: lectureID) {
            guard queuesOnOpen, let services else { return }
            do {
                try await LectureNotesRepository(store: services.records).queueIfNeeded(lectureID: lectureID)
            } catch {
                CoursesUILog.ui.error("Queueing the lecture's notes failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: page.lecture?.title.isEmpty == false ? page.lecture?.title ?? "" : String(localized: "Lecture"))
                .font(.title.weight(.semibold))
                .tracking(-0.3)
                .fixedSize(horizontal: false, vertical: true)
            meta
                .font(.system(size: 12))
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
                .keyboardShortcut(.defaultAction)
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
            .padding(.top, 10)
        }
    }

    private var meta: Text {
        var parts: [Text] = []
        if let number = page.lecture?.number { parts.append(Text("Lecture \(number)")) }
        if let held = page.lecture?.heldAt { parts.append(Text(verbatim: SessionText(locale: locale, timeZone: timeZone).day(held))) }
        if let duration = page.duration, duration > 0 {
            parts.append(Text(verbatim: TimeText.clock(duration)).font(.mono(11.5)).monospacedDigit())
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

/// Keep in mind (the brief's third zone, at the end): the lecture's tracked items on one line
/// each: [ring = due, bar = class, filled = done | title with its faint source glyph | day, mono
/// time]; tracked items, never Claude's wording.
private struct KeepInMindBlock: View {
    let items: [TrackedItem]
    let trails: [TrackedItem.ID: [SourceTrailEntry]]
    let course: Course?
    let text: SessionText

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Keep in mind")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Hairline().padding(.leading, 22)
                    }
                    row(item)
                }
            }
        }
    }

    private func row(_ item: TrackedItem) -> some View {
        let done = item.status == .done
        let color = Color.course(course)
        return HStack(spacing: 12) {
            Group {
                if done {
                    Circle().fill(color).frame(width: 10, height: 10)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 6, weight: .heavy)).foregroundStyle(.white))
                } else if item.kind == .announcement {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 18)
                } else {
                    DueRing(color: color)
                }
            }
            .frame(width: 10)
            HStack(spacing: 6) {
                Text(verbatim: item.title)
                    .font(.body.weight(done ? .regular : .medium))
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(1)
                SourceTrailButton(entries: trails[item.id] ?? [], now: Date(), inCalendar: item.calendarEventID != nil)
            }
            Spacer(minLength: 8)
            if let due = item.dueAt {
                if item.isAllDay {
                    Text(verbatim: text.day(due))
                } else {
                    Text("\(Text(verbatim: text.day(due))), \(Text(verbatim: DayText.time(due, timeZone: text.timeZone)).font(.mono(11.5)).foregroundStyle(.secondary))")
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(done ? .secondary : .primary)
        .frame(minHeight: 31)
    }
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
