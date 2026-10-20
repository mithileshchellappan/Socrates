import Courses
import StudyCore
import StudyUI
import SwiftUI

/// One exam/exercise rule: who said it (orange professor pin), the rule in bold-title form, the
/// jump to where it was said (one chip), and Confirm while an AI-read rule waits.
struct RuleRow: View {
    let rule: CourseRule
    let lectureNumber: Int?
    let update: (CourseRule) -> Void
    let delete: (CourseRule.ID) -> Void
    let open: (Lecture.ID, ReviewTarget) -> Void
    @State private var editing: Bool

    init(
        rule: CourseRule,
        lectureNumber: Int?,
        editing: Bool = false,
        update: @escaping (CourseRule) -> Void,
        delete: @escaping (CourseRule.ID) -> Void,
        open: @escaping (Lecture.ID, ReviewTarget) -> Void
    ) {
        self.rule = rule
        self.lectureNumber = lectureNumber
        self.update = update
        self.delete = delete
        self.open = open
        _editing = State(initialValue: editing)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            marker
                .frame(width: 16)
            Button {
                editing = true
            } label: {
                ruleText
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                RuleEditor(rule: rule, update: update, delete: delete)
            }
            sourceChip
            if !rule.isConfirmed {
                Button("Confirm", action: confirm)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        // The mockup's `.rule`: 35 pt for one line, wrapped lines 18.5 pt apart.
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(minHeight: 35)
        .contextMenu {
            Button("Edit…") { editing = true }
            if !rule.isConfirmed {
                Button("Confirm", action: confirm)
            }
            if !rule.title.isEmpty || !rule.text.isEmpty {
                Divider()
                Button("Delete", role: .destructive) { delete(rule.id) }
            }
        }
    }

    /// "L2 · 0:20" for something said in a lecture, "S13" for a slide.
    @ViewBuilder
    private var sourceChip: some View {
        if let source = rule.source, let lectureID = source.lectureID {
            if source.kind == .slide, let page = source.pageNumber {
                SlideChip(page: page) { open(lectureID, ReviewTarget(page: page)) }
            } else if let time = source.time {
                TimeChip(time, prefix: lectureNumber.map { "L\($0)" }) {
                    open(lectureID, ReviewTarget(time: time, plays: true, recordingID: source.recordingID))
                }
            }
        }
    }

    private func confirm() {
        var confirmed = rule
        confirmed.confirmedAt = Date()
        update(confirmed)
    }

    @ViewBuilder
    private var marker: some View {
        if rule.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(Text("Not announced"))
        } else if rule.provenance == .professor || (rule.provenance == .ai && saidInClass) {
            ProvenancePin(.professor)
        } else if rule.provenance == .user {
            ProvenancePin(.user)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private var saidInClass: Bool {
        guard let kind = rule.source?.kind else { return false }
        return kind == .transcript || kind == .slide
    }

    private var ruleText: Text {
        let title = rule.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = Text(title.isEmpty ? "" : "\(title).").fontWeight(.semibold)
        let body = rule.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return Text("\(heading) \(Text("Not announced").foregroundStyle(.tertiary))")
        }
        if !rule.isConfirmed {
            let mark = Text(Image(systemName: "sparkle")).font(.caption).foregroundStyle(Color.ai)
            return Text("\(heading) \(mark) \(Text(body).foregroundStyle(.secondary))")
        }
        return Text("\(heading) \(body)")
    }
}

/// Edits a rule's title and wording.
struct RuleEditor: View {
    let original: CourseRule
    let update: (CourseRule) -> Void
    let delete: (CourseRule.ID) -> Void
    @State private var rule: CourseRule
    @FocusState private var focus: Field?

    private enum Field {
        case title
        case text
    }

    init(rule: CourseRule, update: @escaping (CourseRule) -> Void, delete: @escaping (CourseRule.ID) -> Void) {
        original = rule
        self.update = update
        self.delete = delete
        _rule = State(initialValue: rule)
    }

    var body: some View {
        Form {
            TextField("Title", text: $rule.title, prompt: Text("Exam admission"))
                .focused($focus, equals: .title)
            TextField("Rule", text: $rule.text, prompt: Text("Take part in the online quizzes."), axis: .vertical)
                .lineLimit(2...5)
                .focused($focus, equals: .text)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focus = original.title.isEmpty ? .title : (original.text.isEmpty ? .text : nil) }
        .onDisappear(perform: commit)
    }

    private func commit() {
        var edited = rule
        edited.title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.text = edited.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if edited.title.isEmpty, edited.text.isEmpty {
            delete(original.id)
            return
        }
        guard edited != original else { return }
        if edited.provenance == .ai, edited.text != original.text {
            // Rewording an agent's rule makes it the user's.
            edited.provenance = .user
            edited.confirmedAt = Date()
        }
        update(edited)
    }
}

extension MailRuleKind {
    /// The kinds Course Settings offers, in menu order (the platform's course once the profile
    /// names a learning platform).
    static var settingsKinds: [MailRuleKind] {
        UniversityProfile.current.platformMarker.isEmpty ? [.sender, .listID, .subject] : [.sender, .listID, .subject, .platformCourse]
    }

    /// "Sender is", "Mailing list is", "Subject contains", "<platform> course is".
    var settingsTitle: String {
        switch self {
        case .sender: String(localized: "Sender is")
        case .listID: String(localized: "Mailing list is")
        case .subject: String(localized: "Subject contains")
        case .platformCourse:
            UniversityProfile.current.platformMarker.isEmpty
                ? String(localized: "Learning platform course is")
                : String(localized: "\(UniversityProfile.current.platformName) course is")
        default: rawValue
        }
    }
}

/// A mail routing rule (`mail_rule`): which part of a message to look at, as a pop-up button, and
/// what it contains, as a token that edits in place. Learned rules are secondary. A rule whose
/// value is emptied is deleted.
struct MailRuleRow: View {
    let rule: MailRule
    var focusesOnAppear = false
    let save: (MailRule) -> Void
    let delete: (MailRule) -> Void

    @State private var value = ""
    @State private var isHovered = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            PopUpPicker(title: "Field", selection: kind, options: kindOptions)

            Text(verbatim: value.isEmpty ? " " : value)
                .hidden()
                .frame(minWidth: 40, alignment: .leading)
                .overlay(alignment: .leading) {
                    TextField("Value", text: $value)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                }
                .tokenStyle()
                .foregroundStyle(rule.origin == .learned ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .focusRing(focused, cornerRadius: 5, border: false)

            Spacer(minLength: 0)
            Button {
                delete(rule)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(isHovered || focused ? 1 : 0)
            .accessibilityLabel(Text("Delete Rule"))
        }
        .foregroundStyle(rule.origin == .learned ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .settingsRowPadding()
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onAppear { value = rule.pattern }
        .task {
            // After the row is in the window, so the field can take focus.
            guard focusesOnAppear else { return }
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
        .onChange(of: rule.pattern) {
            if !focused { value = rule.pattern }
        }
        .onChange(of: focused) {
            if !focused { commit() }
        }
        .contextMenu {
            Button("Delete", role: .destructive) { delete(rule) }
        }
    }

    private var kindOptions: [ChoiceOption<MailRuleKind>] {
        var kinds = MailRuleKind.settingsKinds
        if !kinds.contains(rule.kind) { kinds.append(rule.kind) }
        return kinds.map { ChoiceOption(value: $0, label: $0.settingsTitle) }
    }

    private var kind: Binding<MailRuleKind> {
        Binding(
            get: { rule.kind },
            set: { kind in
                var changed = rule
                changed.kind = kind
                changed.pattern = value.trimmingCharacters(in: .whitespacesAndNewlines)
                save(changed)
            }
        )
    }

    private func commit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(rule)
            return
        }
        guard trimmed != rule.pattern else { return }
        var changed = rule
        changed.pattern = trimmed
        if changed.origin == .learned {
            // Rewording a learned rule makes it the student's.
            changed.origin = .user
        }
        save(changed)
    }
}

/// The Mail group of a course without rules (mockup 08's rule rows, in tertiary): "Sender is" and
/// the course's lecturer, or "<platform> course is" (else "Subject contains") and the course's
/// name. Clicking it keeps that rule.
struct GhostMailRuleRow: View {
    let rule: MailRule
    let add: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: add) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Text(rule.kind.settingsTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .frame(width: 12)
                }
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .frame(height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                Text(rule.pattern)
                    .tokenStyle()
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.tertiary)
            .settingsRowPadding()
            .background(isHovered ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text("Add Rule"))
        .accessibilityValue(Text(verbatim: "\(rule.kind.settingsTitle) \(rule.pattern)"))
    }

    /// The rule a course most likely wants: mail from its lecturer, else its course on the
    /// learning platform, else its name in the subject.
    static func rule(for course: Course, sortOrder: Int) -> MailRule {
        if let lecturer = course.professors.first.map(Self.plainName), !lecturer.isEmpty {
            return MailRule(courseID: course.id, kind: .sender, pattern: lecturer, sortOrder: sortOrder)
        }
        let kind: MailRuleKind = UniversityProfile.current.platformMarker.isEmpty ? .subject : .platformCourse
        return MailRule(courseID: course.id, kind: kind, pattern: course.name, sortOrder: sortOrder)
    }

    /// "Prof. Dr. Ada Example" → "Ada Example" (a sender's display name has no titles).
    static func plainName(_ name: String) -> String {
        let titles: Set<String> = ["prof.", "dr.", "prof", "dr", "jun.-prof.", "apl.", "pd", "dipl.-inf."]
        return name.split(whereSeparator: \.isWhitespace)
            .filter { !titles.contains($0.lowercased()) }
            .joined(separator: " ")
    }
}
