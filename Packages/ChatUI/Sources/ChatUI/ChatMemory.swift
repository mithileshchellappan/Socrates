import StudyCore
import StudyUI
import SwiftUI

/// The chat header's ⋯ (mockup 07): Memory… (and, where the header has no New Chat button of its
/// own, New Chat). Opens the memory sheet itself.
public struct ChatMoreMenu: View {
    private let newChat: (() -> Void)?
    @State private var showsMemory = false

    /// `newChat`: adds New Chat to the menu (Review's Tutor tab, whose header is the review's).
    public init(newChat: (() -> Void)? = nil) {
        self.newChat = newChat
    }

    public var body: some View {
        Menu {
            if let newChat {
                Button("New Chat", action: newChat)
            }
            Button("Memory…") { showsMemory = true }
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help(Text("More"))
        .sheet(isPresented: $showsMemory) {
            ChatMemorySheet()
        }
    }
}

/// What the agent keeps about the student (`agent_memory`, M5): You, Preferences, then each
/// course (dot + name). The text is edited in place (`AgentMemoryRepository.edit`); the student's
/// own words it was written from show on hover; Forget in the context menu and on ⌫ (forgotten
/// rows are never shown or sent again, nothing is deleted). No add button, no copy.
public struct ChatMemorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyServices) private var services
    @FetchAll(AgentMemory.where { $0.forgottenAt.is(nil) }.order(by: \.createdAt)) private var memories
    @FetchAll(Course.order(by: \.sortOrder)) private var courses
    @State private var selection: AgentMemory.ID?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Text("Memory")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            if memories.isEmpty {
                ContentUnavailableView {
                    Image(systemName: "brain")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        #if os(macOS)
        .frame(width: 460, height: 440)
        #endif
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.id) { group in
                Section {
                    ForEach(group.memories) { memory in
                        MemoryRow(memory: memory, save: save, forget: forget)
                            .tag(memory.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        if let course = group.course {
                            CourseDot(course: course, size: 8)
                        }
                        Text(verbatim: group.title)
                    }
                }
            }
        }
        #if os(macOS)
        .onDeleteCommand {
            if let selection { forget(selection) }
        }
        #endif
    }

    private struct MemoryGroup {
        var id: String
        var title: String
        var course: Course?
        var memories: [AgentMemory]
    }

    /// You, Preferences, then each course in the sheet's order (`AgentMemoryRepository.ordered`).
    private var groups: [MemoryGroup] {
        var groups: [MemoryGroup] = []
        for memory in AgentMemoryRepository.ordered(memories) {
            let id: String
            let title: String
            var course: Course?
            switch memory.kind {
            case .student:
                id = "student"
                title = String(localized: "You")
            case .preference:
                id = "preference"
                title = String(localized: "Preferences")
            case .course:
                course = courses.first { $0.id == memory.courseID }
                guard let course else { continue }
                id = course.id.uuidString
                title = course.name
            default:
                continue
            }
            if groups.last?.id == id {
                groups[groups.count - 1].memories.append(memory)
            } else {
                groups.append(MemoryGroup(id: id, title: title, course: course, memories: [memory]))
            }
        }
        return groups
    }

    private func save(_ id: AgentMemory.ID, _ text: String) {
        guard let services else { return }
        Task {
            do {
                try await AgentMemoryRepository(store: services.records).edit(id, text: text)
            } catch {
                ChatUILog.ui.error("Editing a memory failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func forget(_ id: AgentMemory.ID) {
        guard let services else { return }
        Task {
            do {
                try await AgentMemoryRepository(store: services.records).forget(id)
            } catch {
                ChatUILog.ui.error("Forgetting a memory failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// One memory: its text, editable in place (saved on ↩ and when the field lets go of focus);
/// the student's quote on hover; Forget in the context menu.
private struct MemoryRow: View {
    let memory: AgentMemory
    let save: (AgentMemory.ID, String) -> Void
    let forget: (AgentMemory.ID) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1...4)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: memory.text, initial: true) { _, stored in
                if !isFocused { text = stored }
            }
            .help(Text(verbatim: "“\(memory.quote)”"))
            .contextMenu {
                Button("Forget") { forget(memory.id) }
            }
    }

    private func commit() {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AgentMemory.textLimit))
        guard !trimmed.isEmpty else {
            text = memory.text
            return
        }
        guard trimmed != memory.text else { return }
        save(memory.id, trimmed)
    }
}
