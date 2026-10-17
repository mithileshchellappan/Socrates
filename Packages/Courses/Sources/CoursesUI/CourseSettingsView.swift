import CalendarSync
import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Course setup (mockup 08): who teaches it and in which language, the glossary, its slides,
/// when it meets, the exam and exercise rules, recording consent and mail routing. Two columns
/// when there is room, one otherwise. Edits save as they happen; slot changes replan the
/// sessions and update the calendar.
public struct CourseSettingsView: View {
    private let courseID: Course.ID
    private let changeDeck: (Deck.ID) -> Void

    @FetchOne private var course: Course?
    @FetchAll private var slots: [WeeklySlot]
    @FetchAll private var lectures: [Lecture]
    @Fetch private var decks: [CourseDeck]

    @Environment(\.studyServices) private var services
    @Environment(\.calendarMirror) private var mirror
    @Environment(\.openDestination) private var openDestination
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @State private var draft: Course?
    @State private var saved: Course?
    @State private var isWide = true
    @State private var newSlotID: WeeklySlot.ID?
    @State private var newRuleID: CourseRule.ID?

    public init(courseID: Course.ID, changeDeck: @escaping (Deck.ID) -> Void = { _ in }) {
        self.courseID = courseID
        self.changeDeck = changeDeck
        _course = FetchOne(Course.find(courseID))
        _slots = FetchAll(WeeklySlot.where { $0.courseID.eq(courseID) }.order { ($0.weekday, $0.startMinute) })
        _lectures = FetchAll(Lecture.where { $0.courseID.eq(courseID) })
        _decks = Fetch(wrappedValue: [], CourseDecksRequest(courseID: courseID))
    }

    public var body: some View {
        Group {
            if let binding = Binding($draft) {
                layout(binding)
            } else {
                Color.clear
            }
        }
        .navigationTitle("Course Settings")
        .navigationSubtitle(draft?.name ?? course?.name ?? "")
        .onAppear { adopt(course) }
        .onChange(of: course) { adopt(course) }
        .task(id: draft) { await saveSoon() }
        .onDisappear(perform: saveNow)
    }

    // MARK: - Layout

    @ViewBuilder
    private func layout(_ course: Binding<Course>) -> some View {
        Group {
            if isWide {
                HStack(alignment: .top, spacing: 0) {
                    Form { leftSections(course) }
                        .formStyle(.grouped)
                    Form { rightSections(course) }
                        .formStyle(.grouped)
                }
            } else {
                Form {
                    leftSections(course)
                    rightSections(course)
                }
                .formStyle(.grouped)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { isWide = $0 }
    }

    @ViewBuilder
    private func leftSections(_ course: Binding<Course>) -> some View {
        Section("Course") {
            LabeledContent("Name") {
                HStack(spacing: 6) {
                    CourseColorMenu(hex: course.colorHex)
                    TextField("Name", text: course.name)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 236)
                }
            }
            LabeledContent(course.wrappedValue.professors.count > 1 ? "Lecturers" : "Lecturer") {
                NamesField(title: "Lecturer", names: course.professors)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 236)
            }
            LabeledContent("Language") {
                HStack(spacing: 6) {
                    languagePicker("Language", selection: course.language, current: course.wrappedValue.language)
                    Text("admin parts in")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    languagePicker("Admin Language", selection: course.adminLanguage, current: course.wrappedValue.adminLanguage)
                }
            }
        }

        Section("Glossary") {
            GlossaryField(terms: course.glossaryTerms)
        }

        if !decks.isEmpty {
            Section("Slides") {
                ForEach(decks) { item in
                    DeckRow(item: item, text: sessionText) { changeDeck(item.deck.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func rightSections(_ course: Binding<Course>) -> some View {
        Section {
            if !orderedSlots.isEmpty {
                SlotHeaderRow()
            }
            ForEach(orderedSlots) { slot in
                SlotRow(
                    slot: slot, text: sessionText,
                    save: { actions.save($0) },
                    delete: { actions.deleteSlot($0) },
                    editsTimeInitially: slot.id == newSlotID
                )
            }
            Toggle("Show in Calendar", isOn: course.showsInCalendar)
        } header: {
            SectionHeader("Weekly slots") {
                Button("Add Slot", action: addSlot)
            }
        }

        Section {
            ForEach(course.wrappedValue.rules) { rule in
                RuleRow(
                    rule: rule,
                    lectureNumber: rule.source?.lectureID.flatMap { id in lectures.first { $0.id == id }?.number },
                    editing: rule.id == newRuleID,
                    update: { changed in
                        guard let index = draft?.rules.firstIndex(where: { $0.id == changed.id }) else { return }
                        draft?.rules[index] = changed
                    },
                    delete: { id in draft?.rules.removeAll { $0.id == id } },
                    play: { lectureID, time in
                        openDestination(.lecture(lectureID, ReviewTarget(time: time, plays: true)))
                    }
                )
            }
        } header: {
            SectionHeader("Exam & exercises") {
                Button("Add Rule", action: addRule)
            }
        }

        Section("Recording") {
            Toggle("Record this course", isOn: Binding(
                get: { course.wrappedValue.recordsLectures },
                set: { on in course.wrappedValue.recordingConsentAt = on ? (course.wrappedValue.recordingConsentAt ?? Date()) : nil }
            ))
            Picker("Scope", selection: course.recordingScope) {
                Text("Lecturer only").tag(RecordingScope.lecturer)
                Text("Whole room").tag(RecordingScope.room)
            }
            .pickerStyle(.segmented)
        }

        Section {
            ForEach(Array(course.wrappedValue.mailRules.enumerated()), id: \.offset) { index, rule in
                MailRuleRow(
                    rule: rule,
                    update: { changed in
                        guard let count = draft?.mailRules.count, index < count else { return }
                        draft?.mailRules[index] = changed
                    },
                    delete: {
                        guard let count = draft?.mailRules.count, index < count else { return }
                        draft?.mailRules.remove(at: index)
                    }
                )
            }
        } header: {
            SectionHeader("Mail") {
                Button("Add Rule") { draft?.mailRules.append(MailRoutingRule(field: .from, contains: "")) }
            }
        }
    }

    private func languagePicker(_ title: LocalizedStringKey, selection: Binding<String>, current: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(languageChoices(including: current), id: \.code) { language in
                Text(language.name).tag(language.code)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Actions

    private var actions: ScheduleActions { ScheduleActions(services: services, mirror: mirror) }

    /// Lectures first, then exercises, tutorials, seminars; each by weekday and time.
    private var orderedSlots: [WeeklySlot] {
        func rank(_ kind: SessionKind) -> Int { SessionKind.slotKinds.firstIndex(of: kind) ?? SessionKind.slotKinds.count }
        return slots.sorted { lhs, rhs in
            (rank(lhs.kind), lhs.weekday, lhs.startMinute, lhs.id.uuidString) < (rank(rhs.kind), rhs.weekday, rhs.startMinute, rhs.id.uuidString)
        }
    }

    private var sessionText: SessionText { SessionText(locale: locale, timeZone: timeZone) }

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

    // MARK: - Saving

    /// Takes the stored course unless the user has unsaved edits.
    private func adopt(_ fetched: Course?) {
        guard let fetched else { return }
        guard let draft, let saved else {
            draft = fetched
            saved = fetched
            return
        }
        if fetched.hasSameContent(as: draft) {
            self.saved = fetched
        } else if draft.hasSameContent(as: saved) {
            self.draft = fetched
            self.saved = fetched
        }
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
        actions.run("Saving a course", syncCalendar: calendarChanged) { services in
            try await CourseLibrary(services: services).save(draft)
        }
    }
}

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

private struct DeckRow: View {
    let item: CourseDeck
    let text: SessionText
    let change: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.deck.title.isEmpty ? item.deck.fileName : item.deck.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let tag {
                    HStack(spacing: 5) {
                        Image(systemName: "tag")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                        Text(tag)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Change", action: change)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
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
