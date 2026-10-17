import Courses
import StudyCore
import StudyUI
import SwiftUI

/// One exam/exercise rule: who said it (orange professor pin), the rule in bold-title form, the
/// jump to where it was said, and Confirm while an AI-read rule waits.
struct RuleRow: View {
    let rule: CourseRule
    let lectureNumber: Int?
    let update: (CourseRule) -> Void
    let delete: (CourseRule.ID) -> Void
    let play: (Lecture.ID, Double) -> Void
    @State private var editing: Bool

    init(
        rule: CourseRule,
        lectureNumber: Int?,
        editing: Bool = false,
        update: @escaping (CourseRule) -> Void,
        delete: @escaping (CourseRule.ID) -> Void,
        play: @escaping (Lecture.ID, Double) -> Void
    ) {
        self.rule = rule
        self.lectureNumber = lectureNumber
        self.update = update
        self.delete = delete
        self.play = play
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
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                RuleEditor(rule: rule, update: update, delete: delete)
            }
            if let source = rule.source, let lectureID = source.lectureID, let time = source.time {
                LectureTimeChip(lectureNumber: lectureNumber, seconds: time) { play(lectureID, time) }
            }
            if !rule.isConfirmed {
                Button("Confirm") {
                    var confirmed = rule
                    confirmed.confirmedAt = Date()
                    update(confirmed)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit…") { editing = true }
            if !rule.isConfirmed {
                Button("Confirm") {
                    var confirmed = rule
                    confirmed.confirmedAt = Date()
                    update(confirmed)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { delete(rule.id) }
        }
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
            return Text("\(heading) \(Text("\(Image(systemName: "sparkle")) \(body)").foregroundStyle(.secondary))")
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
    @FocusState private var titleFocused: Bool

    init(rule: CourseRule, update: @escaping (CourseRule) -> Void, delete: @escaping (CourseRule.ID) -> Void) {
        original = rule
        self.update = update
        self.delete = delete
        _rule = State(initialValue: rule)
    }

    var body: some View {
        Form {
            TextField("Title", text: $rule.title, prompt: Text("Exam admission"))
                .focused($titleFocused)
            TextField("Rule", text: $rule.text, prompt: Text("Take part in the online quizzes."), axis: .vertical)
                .lineLimit(2...5)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { titleFocused = original.title.isEmpty }
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

/// A mail routing rule: which header to look at and what it contains (used from M2).
struct MailRuleRow: View {
    let rule: MailRoutingRule
    let update: (MailRoutingRule) -> Void
    let delete: () -> Void
    @State private var value = ""
    @State private var isHovered = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: Binding(get: { rule.field }, set: { field in
                var changed = rule
                changed.field = field
                update(changed)
            })) {
                Text("Sender is").tag(MailRoutingRule.Field.from)
                Text("Subject contains").tag(MailRoutingRule.Field.subject)
                Text("Mailing list is").tag(MailRoutingRule.Field.listID)
            }
            .labelsHidden()
            .fixedSize()

            TextField("Value", text: $value)
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) {
                    if !focused { commit() }
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .fixedSize()
                .frame(minWidth: 60, alignment: .leading)

            Spacer(minLength: 0)
            Button(action: delete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(isHovered || focused ? 1 : 0)
            .accessibilityLabel(Text("Delete Rule"))
        }
        .onHover { isHovered = $0 }
        .onAppear { value = rule.contains }
        .onChange(of: rule.contains) {
            if !focused { value = rule.contains }
        }
        .contextMenu {
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func commit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != rule.contains else { return }
        var changed = rule
        changed.contains = trimmed
        update(changed)
    }
}
