import Courses
import StudyCore
import StudyUI
import SwiftUI

/// The semester in Settings: its name, lecture period and breaks. Changes replan every course's
/// sessions and update the calendar.
public struct SemesterSettingsView: View {
    @FetchAll(Semester.order(by: \.lectureStart)) private var semesters
    @Environment(\.studyServices) private var services
    @Environment(\.calendarMirror) private var mirror

    @State private var selection: Semester.ID?
    @State private var draft: Semester?
    @State private var saved: Semester?

    public init() {}

    public var body: some View {
        Form {
            if semesters.count > 1 {
                Picker("Semester", selection: $selection) {
                    ForEach(semesters) { semester in
                        Text(semester.name).tag(Semester.ID?.some(semester.id))
                    }
                }
            }
            if let semester = Binding($draft) {
                Section {
                    TextField("Name", text: semester.name)
                    LabeledContent("Lectures") {
                        HStack(spacing: 6) {
                            dayPicker("First Day", day: semester.lectureStart)
                            Text(verbatim: "–").foregroundStyle(.secondary)
                            dayPicker("Last Day", day: semester.lectureEnd)
                        }
                    }
                }
                Section {
                    ForEach(Array(semester.wrappedValue.breaks.enumerated()), id: \.offset) { index, item in
                        BreakRow(
                            item: item,
                            update: { changed in
                                guard let count = draft?.breaks.count, index < count else { return }
                                draft?.breaks[index] = changed
                            },
                            delete: {
                                guard let count = draft?.breaks.count, index < count else { return }
                                draft?.breaks.remove(at: index)
                            }
                        )
                    }
                } header: {
                    SectionHeader("Breaks") {
                        Button("Add Break", action: addBreak)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: choose)
        .onChange(of: semesters) { choose() }
        .onChange(of: selection) { choose() }
        .task(id: draft) { await saveSoon() }
        .onDisappear(perform: saveNow)
    }

    private func dayPicker(_ title: LocalizedStringKey, day: Binding<CalendarDay>) -> some View {
        DatePicker(title, selection: Binding(
            get: { DayClock.date(day.wrappedValue) },
            set: { day.wrappedValue = DayClock.day($0) }
        ), displayedComponents: .date)
        .labelsHidden()
        .environment(\.timeZone, .gmt)
    }

    private func addBreak() {
        guard let draft else { return }
        let start = draft.lectureStart.adding(days: 7)
        self.draft?.breaks.append(SemesterBreak(name: "", first: start, last: start))
    }

    /// Shows the selected semester (the current one at first) unless the user has unsaved edits.
    private func choose() {
        if selection == nil || !semesters.contains(where: { $0.id == selection }) {
            selection = semesters.isEmpty ? nil : Semester.current(among: semesters).id
        }
        guard let fetched = semesters.first(where: { $0.id == selection }) else { return }
        guard let draft, let saved, draft.id == fetched.id else {
            saveNow()
            self.draft = fetched
            self.saved = fetched
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
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        saveNow()
    }

    private func saveNow() {
        guard let draft, let saved, draft.id == saved.id, !draft.hasSameContent(as: saved) else { return }
        var cleaned = draft
        cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.breaks = cleaned.breaks.map { item in
            var item = item
            if item.last < item.first { item.last = item.first }
            return item
        }
        guard cleaned.lectureStart <= cleaned.lectureEnd else { return }
        self.saved = draft
        ScheduleActions(services: services, mirror: mirror).save(cleaned)
    }
}

private struct BreakRow: View {
    let item: SemesterBreak
    let update: (SemesterBreak) -> Void
    let delete: () -> Void
    @State private var name = ""
    @State private var isHovered = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Name", text: $name, prompt: Text("Christmas break"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .onSubmit(commitName)
                .onChange(of: nameFocused) {
                    if !nameFocused { commitName() }
                }
            Spacer(minLength: 8)
            day(\.first)
            Text(verbatim: "–").foregroundStyle(.secondary)
            day(\.last)
            Button(action: delete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(isHovered || nameFocused ? 1 : 0)
            .accessibilityLabel(Text("Delete Break"))
        }
        .onHover { isHovered = $0 }
        .onAppear { name = item.name }
        .onChange(of: item.name) {
            if !nameFocused { name = item.name }
        }
        .contextMenu {
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func day(_ keyPath: WritableKeyPath<SemesterBreak, CalendarDay>) -> some View {
        DatePicker("Day", selection: Binding(
            get: { DayClock.date(item[keyPath: keyPath]) },
            set: { date in
                var changed = item
                changed[keyPath: keyPath] = DayClock.day(date)
                update(changed)
            }
        ), displayedComponents: .date)
        .labelsHidden()
        .environment(\.timeZone, .gmt)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != item.name else { return }
        var changed = item
        changed.name = trimmed
        update(changed)
    }
}
