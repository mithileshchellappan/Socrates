import CalendarSync
import Courses
import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

/// Course setup (mockup 08): who teaches it and in which language, the glossary with its
/// suggestions, its slides, when it meets, the exam and exercise rules, recording consent and
/// mail routing. Two columns when there is room, one otherwise. Edits save as they happen; slot
/// changes replan the sessions and update the calendar.
public struct CourseSettingsView: View {
    private let courseID: Course.ID
    private let changeDeck: (Deck.ID) -> Void
    private let importFiles: (() -> Void)?
    private let importDropped: (([URL]) -> Void)?
    private let newCourse: (() -> Void)?

    @FetchOne private var course: Course?
    @FetchAll private var slots: [WeeklySlot]
    @FetchAll private var lectures: [Lecture]
    @FetchAll private var oneOffSessions: [LectureSession]
    /// From yesterday on, for the next class an empty Slides group stands for.
    @FetchAll private var upcomingSessions: [LectureSession]
    @FetchAll private var mailRules: [MailRule]
    @Fetch private var decks: [CourseDeck]
    @Fetch private var vocabulary: GlossaryVocabulary
    @AppStorage private var dismissedTerms: String

    @Environment(\.studyServices) private var services
    @Environment(\.calendarMirror) private var mirror
    @Environment(\.importTimetable) private var importTimetable
    @Environment(\.openDestination) private var openDestination
    @Environment(\.deleteFromLibrary) private var deleteFromLibrary
    @Environment(\.undoManager) private var undoManager
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @State private var draft: Course?
    @State private var saved: Course?
    /// This view's saves not yet read back, oldest first (at most 8).
    @State private var written: [Course] = []
    @State private var isWide = true
    @State private var newSlotID: WeeklySlot.ID?
    @State private var newRuleID: CourseRule.ID?
    @State private var newMailRule: MailRule?
    @State private var importsCalendar = false
    @State private var undoTarget = UndoTarget()
    /// Stands in for the exam form until the course has one (saved once it is edited).
    @State private var examFormPlaceholder = CourseRule(kind: .examForm, title: String(localized: "Exam form"))
    @FocusState private var nameFocused: Bool

    /// - Parameters:
    ///   - changeDeck: Change… on a deck (the filing change sheet).
    ///   - importFiles: Import in the toolbar and in an empty Slides group (the file importer for
    ///     this course). Nil: the app shows its own Import.
    ///   - importDropped: Files dropped on an empty Slides group, filed into this course.
    ///   - newCourse: New Course… in the toolbar's More menu.
    public init(
        courseID: Course.ID,
        changeDeck: @escaping (Deck.ID) -> Void = { _ in },
        importFiles: (() -> Void)? = nil,
        importDropped: (([URL]) -> Void)? = nil,
        newCourse: (() -> Void)? = nil
    ) {
        self.courseID = courseID
        self.changeDeck = changeDeck
        self.importFiles = importFiles
        self.importDropped = importDropped
        self.newCourse = newCourse
        _course = FetchOne(Course.find(courseID))
        _slots = FetchAll(WeeklySlot.where { $0.courseID.eq(courseID) }.order { ($0.weekday, $0.startMinute) })
        _lectures = FetchAll(Lecture.where { $0.courseID.eq(courseID) })
        _oneOffSessions = FetchAll(LectureSession.where { $0.courseID.eq(courseID) && $0.weeklySlotID.is(nil) })
        // Rounded to the day, so the request stays the same while the view is re-created.
        let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)
        _upcomingSessions = FetchAll(
            LectureSession.where { $0.courseID.eq(courseID) && !$0.isCancelled && $0.endsAt.gte(since) }.order(by: \.startsAt)
        )
        _mailRules = FetchAll(MailRule.where { $0.courseID.eq(courseID) }.order { ($0.sortOrder, $0.createdAt) })
        _decks = Fetch(wrappedValue: [], CourseDecksRequest(courseID: courseID))
        _vocabulary = Fetch(wrappedValue: .empty, GlossaryVocabularyRequest(courseID: courseID))
        _dismissedTerms = AppStorage(wrappedValue: "", "GlossaryDismissed-\(courseID.uuidString)")
    }

    public var body: some View {
        Group {
            if let binding = Binding($draft) {
                layout(binding)
            } else {
                Color.clear
            }
        }
        .screenTitle(String(localized: "Course Settings"), subtitle: draft?.name ?? course?.name ?? "")
        .toolbar { toolbar }
        .fileImporter(isPresented: $importsCalendar, allowedContentTypes: calendarTypes, allowsMultipleSelection: true) { result in
            importCalendar(result)
        }
        .onAppear { adopt(course) }
        .onChange(of: course) { adopt(course) }
        // A name stored by someone else while the field had focus comes in when it is left.
        .onChange(of: nameFocused) { if !nameFocused { adopt(course) } }
        .task(id: draft) { await saveSoon() }
        .onDisappear(perform: saveNow)
    }

    // MARK: - Layout

    @ViewBuilder
    private func layout(_ course: Binding<Course>) -> some View {
        ScrollView {
            Group {
                if isWide {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 14) { leftGroups(course) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 14) { rightGroups(course) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        leftGroups(course)
                        rightGroups(course)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 2)
            .padding(.bottom, 22)
        }
        .background(Color.fieldBackground)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { isWide = $0 }
    }

    @ViewBuilder
    private func leftGroups(_ course: Binding<Course>) -> some View {
        SettingsGroup("Course") {
            FormRow("Name") {
                HStack(spacing: 7) {
                    CourseColorMenu(hex: course.colorHex)
                    TextField("Name", text: course.name)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                }
                .fieldChrome(isFocused: nameFocused)
            }
            FormRow(course.wrappedValue.professors.count > 1 ? Text("Lecturers") : Text("Lecturer")) {
                NamesField(title: "Lecturer", names: course.professors, chrome: true)
            }
            FormRow("Language") {
                languagePicker("Language", selection: course.language, current: course.wrappedValue.language)
                Text("admin parts in")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                languagePicker("Admin Language", selection: course.adminLanguage, current: course.wrappedValue.adminLanguage)
            }
        }

        SettingsGroup("Glossary") {
            GlossaryField(terms: course.glossaryTerms) { prefix in
                vocabulary.completion(for: prefix, excluding: course.wrappedValue.glossaryTerms)
            }
            let suggestions = glossarySuggestions(for: course.wrappedValue)
            if !suggestions.isEmpty {
                SuggestedHeader()
                ForEach(suggestions) { suggestion in
                    GlossarySuggestionRow(
                        suggestion: suggestion,
                        add: { addTerm(suggestion.term) },
                        dismiss: { dismiss(suggestion.term) },
                        open: { openDestination(.lecture($0, $1)) }
                    )
                }
            }
        }

        SettingsGroup("Slides") {
            if decks.isEmpty {
                GhostDeckRow(tag: nextClassTag, importFiles: importFiles, importDropped: importDropped)
            } else {
                ForEach(decks) { item in
                    DeckRow(item: item, text: sessionText) { changeDeck(item.deck.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func rightGroups(_ course: Binding<Course>) -> some View {
        SettingsGroup("Weekly slots") {
            Button("Import .ics") { importsCalendar = true }
            Button("Add Slot", action: addSlot)
        } content: {
            SlotHeaderRow()
            ForEach(orderedSlots) { slot in
                SlotRow(
                    slot: slot, text: sessionText,
                    save: { actions.save($0) },
                    delete: { actions.deleteSlot($0) },
                    editsTimeInitially: slot.id == newSlotID
                )
            }
            if orderedSlots.isEmpty {
                let guess = SlotGuess.slot(courseID: courseID, sessions: oneOffSessions, timeZone: timeZone)
                GhostSlotRow(guess: guess, text: sessionText) {
                    if let guess {
                        actions.adopt(guess)
                    } else {
                        addSlot()
                    }
                }
            }
            SwitchRow(title: "Show in Calendar", isOn: course.showsInCalendar)
        }

        SettingsGroup("Exam & exercises") {
            ForEach(displayedRules(of: course.wrappedValue)) { rule in
                RuleRow(
                    rule: rule,
                    lectureNumber: rule.source?.lectureID.flatMap { id in lectures.first { $0.id == id }?.number },
                    editing: rule.id == newRuleID,
                    update: { changed in
                        if let index = draft?.rules.firstIndex(where: { $0.id == changed.id }) {
                            draft?.rules[index] = changed
                        } else {
                            draft?.rules.append(changed)
                        }
                    },
                    delete: { id in draft?.rules.removeAll { $0.id == id } },
                    open: { openDestination(.lecture($0, $1)) }
                )
            }
        }
        .contextMenu {
            Button("Add Rule", action: addRule)
        }

        SettingsGroup("Recording") {
            SwitchRow(title: "Record this course", isOn: Binding(
                get: { course.wrappedValue.recordsLectures },
                set: { on in course.wrappedValue.recordingConsentAt = on ? (course.wrappedValue.recordingConsentAt ?? Date()) : nil }
            ))
            HStack(spacing: 10) {
                Text("Scope")
                Spacer(minLength: 8)
                SegmentedChoice(title: "Scope", selection: course.recordingScope, options: [
                    ChoiceOption(value: RecordingScope.lecturer, label: String(localized: "Lecturer only")),
                    ChoiceOption(value: RecordingScope.room, label: String(localized: "Whole room")),
                ])
            }
            .settingsRowPadding()
        }

        SettingsGroup("Mail") {
            Button("Add Rule", action: addMailRule)
        } content: {
            // One list for the stored rules and the new one: the new row keeps its identity (and
            // its field's focus) when its stored row arrives.
            let rules = displayedMailRules
            ForEach(rules) { rule in
                MailRuleRow(rule: rule, focusesOnAppear: rule.id == newMailRule?.id, save: saveMailRule, delete: deleteMailRule)
            }
            if rules.isEmpty {
                let ghost = GhostMailRuleRow.rule(for: course.wrappedValue, sortOrder: 0)
                GhostMailRuleRow(rule: ghost) { saveMailRule(ghost) }
            }
        }
        .onChange(of: mailRules) {
            // The new rule is stored: its row is a stored one now.
            if let newMailRule, mailRules.contains(where: { $0.id == newMailRule.id }) { self.newMailRule = nil }
        }
    }

    private func languagePicker(_ title: LocalizedStringKey, selection: Binding<String>, current: String) -> some View {
        PopUpPicker(
            title: title, selection: selection,
            options: languageChoices(including: current).map { ChoiceOption(value: $0.code, label: $0.name) }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(macOS)
        // The title is a toolbar item (`screenTitle`): this keeps Import and More trailing.
        ToolbarSpacer(.flexible)
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            if let importFiles {
                Button("Import", systemImage: "plus", action: importFiles)
                    .labelStyle(.titleAndIcon)
            }
            Menu {
                Button("Import .ics…") { importsCalendar = true }
                Button("Add Slot", action: addSlot)
                Divider()
                Button("Add Exam Rule", action: addRule)
                Button("Add Mail Rule", action: addMailRule)
                if let newCourse {
                    Divider()
                    Button("New Course…", action: newCourse)
                }
                if let deleteFromLibrary {
                    // The window asks first, naming what goes; Edit ▸ Undo brings it back.
                    Divider()
                    Button("Delete Course…", role: .destructive) { deleteFromLibrary(.course(courseID)) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
        }
    }

    // MARK: - Derived

    private var actions: ScheduleActions { ScheduleActions(services: services, mirror: mirror) }

    /// Lectures first, then exercises, tutorials, seminars; each by weekday and time.
    private var orderedSlots: [WeeklySlot] {
        func rank(_ kind: SessionKind) -> Int { SessionKind.slotKinds.firstIndex(of: kind) ?? SessionKind.slotKinds.count }
        return slots.sorted { lhs, rhs in
            (rank(lhs.kind), lhs.weekday, lhs.startMinute, lhs.id.uuidString) < (rank(rhs.kind), rhs.weekday, rhs.startMinute, rhs.id.uuidString)
        }
    }

    /// The student's rules, then learned ones.
    private var orderedMailRules: [MailRule] {
        mailRules.filter { $0.origin == .user } + mailRules.filter { $0.origin != .user }
    }

    /// The stored rules, then the new one until it is stored.
    private var displayedMailRules: [MailRule] {
        var rules = orderedMailRules
        if let newMailRule, !rules.contains(where: { $0.id == newMailRule.id }) { rules.append(newMailRule) }
        return rules
    }

    /// The course's rules, with "Exam form · Not announced" until it has one.
    private func displayedRules(of course: Course) -> [CourseRule] {
        course.rules.contains { $0.kind == .examForm } ? course.rules : course.rules + [examFormPlaceholder]
    }

    private func glossarySuggestions(for course: Course) -> [GlossarySuggestion] {
        let names = course.professors.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        return vocabulary.suggestions(excluding: course.glossaryTerms + names, dismissed: dismissed)
    }

    private var dismissed: Set<String> {
        Set(dismissedTerms.split(separator: "\n").map(String.init))
    }

    private var sessionText: SessionText { SessionText(locale: locale, timeZone: timeZone) }

    /// "Lecture 3 · Wed 21 Oct", "Seminar 2 · Thu 29 Oct": the next class without a lecture yet
    /// (any kind for a course without lectures), as the sidebar shows it.
    private var nextClassTag: String? {
        let filed = Set(lectures.compactMap(\.lectureSessionID))
        let now = Date()
        let numbered = upcomingSessions.contains { $0.kind == .lecture } ? upcomingSessions.filter { $0.kind == .lecture } : upcomingSessions
        guard let next = numbered.first(where: { $0.endsAt > now && !filed.contains($0.id) }) else { return nil }
        let name = [next.kind.displayName, next.number.map(String.init)].compactMap(\.self).joined(separator: " ")
        return "\(name) · \(sessionText.day(next.startsAt))"
    }

    private var calendarTypes: [UTType] {
        [UTType(filenameExtension: "ics"), .calendarEvent].compactMap(\.self)
    }

    // MARK: - Actions

    private func addSlot() {
        let slot = WeeklySlot(
            courseID: courseID, kind: .lecture, weekday: 1, startMinute: 10 * 60 + 15,
            timeZone: timeZone.identifier
        )
        newSlotID = slot.id
        actions.save(slot)
    }

    private func addRule() {
        let rule = CourseRule(kind: .other, title: "", provenance: .user)
        newRuleID = rule.id
        draft?.rules.append(rule)
    }

    private func addMailRule() {
        let order = (mailRules.map(\.sortOrder).max() ?? -1) + 1
        newMailRule = MailRule(courseID: courseID, kind: .sender, pattern: "", sortOrder: order)
    }

    private func saveMailRule(_ rule: MailRule) {
        if rule.id == newMailRule?.id {
            // The new row stays (with its focused field) until its stored row replaces it.
            newMailRule = rule
        }
        guard !rule.pattern.isEmpty else { return }
        actions.save(rule)
    }

    private func deleteMailRule(_ rule: MailRule) {
        if rule.id == newMailRule?.id {
            newMailRule = nil
        } else {
            actions.delete(rule)
        }
    }

    private func addTerm(_ term: String) {
        guard let terms = draft?.glossaryTerms,
              !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        draft?.glossaryTerms = terms + [term]
    }

    private func dismiss(_ term: String) {
        var terms = dismissed
        terms.insert(term.lowercased())
        dismissedTerms = terms.sorted().joined(separator: "\n")
    }

    /// Weekly slots from .ics files: the app's timetable import for this course (its confirm
    /// sheet), else read here (slots the course has already are skipped; Undo removes them).
    private func importCalendar(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        if let importTimetable {
            importTimetable(urls, courseID: courseID)
            return
        }
        var imported: [WeeklySlot] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                CoursesUILog.ui.error("Could not read \(url.lastPathComponent, privacy: .public)")
                continue
            }
            imported += ICSSlotImporter.slots(from: text, courseID: courseID, existing: slots + imported, timeZone: timeZone)
        }
        guard !imported.isEmpty else { return }
        actions.save(imported)
        Self.registerUndo(of: imported, manager: undoManager, target: undoTarget, actions: actions)
    }

    /// Undo removes the imported slots; Redo adds them again.
    private static func registerUndo(of imported: [WeeklySlot], manager: UndoManager?, target: UndoTarget, actions: ScheduleActions) {
        manager?.registerUndo(withTarget: target) { target in
            actions.deleteSlots(imported.map(\.id))
            manager?.registerUndo(withTarget: target) { target in
                actions.save(imported)
                registerUndo(of: imported, manager: manager, target: target, actions: actions)
            }
        }
        manager?.setActionName(String(localized: "Import Slots"))
    }

    // MARK: - Saving

    /// Takes the stored course unless the student has unsaved edits. This view's own saves coming
    /// back are recognised (an older one arriving after a newer save is ignored, so the Name field
    /// never jumps back), and a change from elsewhere (the agent) never rewrites the field the
    /// student is typing in.
    private func adopt(_ fetched: Course?) {
        guard let fetched else { return }
        guard let draft, let saved else {
            draft = fetched
            saved = fetched
            return
        }
        if let index = written.firstIndex(where: { fetched.hasSameContent(as: $0) }) {
            if index < written.count - 1 {
                // An older save's echo: a newer one follows.
                written.removeFirst(index + 1)
                return
            }
            written.removeAll()
            self.saved = fetched
            return
        }
        if fetched.hasSameContent(as: draft) {
            self.saved = fetched
            return
        }
        guard draft.hasSameContent(as: saved) else { return }
        var merged = fetched
        var base = fetched
        if nameFocused, fetched.name != draft.name {
            // The focused Name field keeps its text (nothing to save: the stored name comes in
            // when the field is left).
            merged.name = draft.name
            base.name = draft.name
        }
        self.draft = merged
        self.saved = base
    }

    private func saveSoon() async {
        guard let draft, let saved, !draft.hasSameContent(as: saved) else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        saveNow()
    }

    private func saveNow() {
        guard let draft, let saved, !draft.hasSameContent(as: saved) else { return }
        let calendarChanged = draft.showsInCalendar != saved.showsInCalendar || draft.name != saved.name
        self.saved = draft
        written.append(draft)
        if written.count > 8 { written.removeFirst() }
        actions.run("Saving a course", syncCalendar: calendarChanged) { services in
            try await CourseLibrary(services: services).save(draft)
        }
    }
}

/// The object Undo registrations hang on.
@MainActor
final class UndoTarget {}

// MARK: - Slides

/// A deck of the course with the lecture it belongs to.
struct CourseDeck: Hashable, Sendable, Identifiable {
    var deck: Deck
    var lecture: Lecture?
    var id: Deck.ID { deck.id }
}

struct CourseDecksRequest: FetchKeyRequest {
    let courseID: Course.ID

    func fetch(_ db: Database) throws -> [CourseDeck] {
        let decks = try Deck.where { $0.courseID.eq(courseID) }.fetchAll(db)
        let lectures = try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db)
        let byID = Dictionary(lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [CourseDeck] = []
        for deck in decks {
            let spanLectures = try LectureDeckSpan
                .where { $0.deckID.eq(deck.id) && $0.startTime.is(nil) }
                .fetchAll(db)
                .compactMap { byID[$0.lectureID] }
            var lecture = spanLectures.min { ($0.heldAt ?? .distantFuture) < ($1.heldAt ?? .distantFuture) }
            if lecture == nil {
                let filing = try Filing.where { $0.deckID.eq(deck.id) }.order { $0.createdAt.desc() }.fetchOne(db)
                lecture = filing?.lectureID.flatMap { byID[$0] }
            }
            items.append(CourseDeck(deck: deck, lecture: lecture))
        }
        return items.sorted { lhs, rhs in
            let lhsDate = lhs.lecture?.heldAt ?? lhs.deck.importedAt
            let rhsDate = rhs.lecture?.heldAt ?? rhs.deck.importedAt
            return lhsDate > rhsDate
        }
    }
}

/// A filed deck: its title, the lecture it is tagged with, and Change (mockup 08: 50 pt rows);
/// its menu has Change… and Delete… (the window confirms, Edit ▸ Undo brings it back).
struct DeckRow: View {
    let item: CourseDeck
    let text: SessionText
    let change: () -> Void
    @Environment(\.deleteFromLibrary) private var deleteFromLibrary

    var body: some View {
        DeckRowLayout(title: item.deck.title.isEmpty ? item.deck.fileName : item.deck.title, tag: tag) {
            Button("Change", action: change)
                .headerActionStyle(inset: 4)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Change…", action: change)
            if let deleteFromLibrary {
                Divider()
                Button("Delete…", role: .destructive) { deleteFromLibrary(.deck(item.deck.id)) }
            }
        }
    }

    private var tag: String? {
        guard let lecture = item.lecture else { return nil }
        var parts: [String] = []
        if let number = lecture.number {
            parts.append(String(localized: "Lecture \(number)"))
        } else if !lecture.title.isEmpty {
            parts.append(lecture.title)
        }
        if let held = lecture.heldAt { parts.append(text.day(held)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A deck row's layout: the PDF glyph, the title over its tag line, the trailing action.
private struct DeckRowLayout<Action: View>: View {
    let title: String
    let tag: String?
    /// A ghost row: everything tertiary.
    var isGhost = false
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 10) {
            PDFGlyph()
                .foregroundStyle(isGhost ? .tertiary : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let tag {
                    HStack(spacing: 5) {
                        Image(systemName: "tag")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(tag)
                    }
                    .font(.subheadline)
                    .foregroundStyle(isGhost ? .tertiary : .secondary)
                }
            }
            .foregroundStyle(isGhost ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
    }
}

/// The Slides group of a course without decks: a deck row in tertiary for the next class ("–",
/// "Seminar 2 · Thu 29 Oct") with Import; PDFs dropped on it are filed into this course.
struct GhostDeckRow: View {
    let tag: String?
    let importFiles: (() -> Void)?
    let importDropped: (([URL]) -> Void)?
    @State private var isTargeted = false

    var body: some View {
        DeckRowLayout(title: "–", tag: tag, isGhost: true) {
            if let importFiles {
                Button("Import", action: importFiles)
                    .headerActionStyle(inset: 4)
                    .controlSize(.small)
            }
        }
        .background(isTargeted ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear))
        .dropDestination(for: URL.self) { urls, _ in
            guard let importDropped, !urls.isEmpty else { return false }
            importDropped(urls)
            return true
        } isTargeted: {
            isTargeted = $0
        }
    }
}

/// The mockup's deck glyph (i-pdf): a page outline with a tiny "PDF" low inside it.
struct PDFGlyph: View {
    var body: some View {
        Image(systemName: "doc")
            .overlay(alignment: .bottom) {
                Text(verbatim: "PDF")
                    .font(.system(size: 4.5, weight: .heavy))
                    .fixedSize()
                    .padding(.bottom, 2.5)
            }
    }
}
