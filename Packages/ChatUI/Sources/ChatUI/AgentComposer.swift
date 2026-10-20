#if os(macOS)
import AppKit
#endif
import StudyCore
import StudyUI
import SwiftUI

/// The panel's composer (DESIGN 8.6, mockup §1, §4): the files waiting as tiles, then [paperclip |
/// the field | Send or Stop] on the content surface, radius 12, a 0.5 pt ring. The prompt names
/// what the next message is about. Send (`arrow.up.circle`, accent outline) appears with text or a
/// file; Stop while the agent works. ↩ sends (a beep while a message cannot go), ⌥↩ and ⇧↩ add a
/// line, ⌘V pastes a file or screenshot, Esc clears (⌘Z brings it back) and then closes the panel.
struct AgentComposer: View {
    let model: AgentPanelModel
    let prompt: Text
    let conversationID: AgentConversation.ID?
    let send: () -> Void

    @Environment(\.agentPanelActions) private var actions
    @Environment(\.studyServices) private var services
    @Environment(\.undoManager) private var undoManager
    @FocusState private var isFocused: Bool
    @State private var showsImporter = false
    /// The caret: put at the end of the kept draft when the panel puts it in the field (a focused
    /// field otherwise selects all of its text, and the next key would replace the draft).
    @State private var selection: TextSelection?
    /// The last caret request (`model.focusRequests`) handled.
    @State private var handledRequest = 0

    private var hasText: Bool { !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { (hasText || model.hasFiles) && model.canSendNow }

    var body: some View {
        @Bindable var model = model
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            if model.hasFiles || model.reading > 0 {
                TileFlow(spacing: 6) {
                    ForEach(model.attachments) { attachment in
                        ComposerAttachmentTile(attachment: attachment) { model.remove(attachment) }
                    }
                    ForEach(0..<model.reading, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(QuietFill())
                            .frame(width: 40, height: 40)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 2) {
                Button {
                    showsImporter = true
                } label: {
                    Label("Attach", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canAttach)
                .help(Text("Attach"))
                // An edit clears the notice line (why the last message or file did not go).
                TextField("", text: Binding(get: { model.draft }, set: { text in
                    model.draft = text
                    if model.notice != nil { model.notice = nil }
                }), selection: $selection, prompt: prompt.foregroundStyle(.tertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onKeyPress(.return, phases: .down) { press in
                        // ⇧↩ adds a line, as ⌥↩ does (after the key, never inside its event).
                        guard press.modifiers.contains(.shift), !FieldEditor.isComposing else { return .ignored }
                        Task { @MainActor in insertLine() }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        // A dead key or an input method's composition: Esc is the input method's
                        // (it cancels the composition).
                        if FieldEditor.isComposing { return .ignored }
                        // Clears or closes after AppKit has finished the key: the field's text never
                        // changes, and the field never goes, inside its own key event.
                        Task { @MainActor in escape() }
                        return .handled
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                    .frame(minHeight: 28)
                if model.isRunning, let conversationID {
                    Button {
                        let actions = actions
                        Task { await actions.stop(conversationID) }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Stop"))
                } else if canSend {
                    Button(action: send) {
                        Label("Send", systemImage: "arrow.up.circle")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(.tint)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Send"))
                }
            }
            .padding(4)
            .frame(minHeight: 36)
        }
        .background {
            // A click on the composer around the field puts the caret in it; a click in the field
            // is the field's own (focus is never set again under the field editor).
            shape
                .fill(Color.contentBackground)
                .onTapGesture { if !isFocused { isFocused = true } }
        }
        .overlay { shape.strokeBorder(.separator, lineWidth: 0.5).allowsHitTesting(false) }
        .onChange(of: isFocused) { _, focused in model.composerFocused = focused }
        .onChange(of: model.focusRequests) { focusSoon() }
        .onAppear {
            if model.focusRequests > 0 { focusSoon() }
        }
        .onDisappear { model.composerFocused = false }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: AttachmentTypes.accepted, allowsMultipleSelection: true) { result in
            guard let services, case .success(let urls) = result else { return }
            model.attach(urls: urls, blobs: services.blobs)
        }
        #if os(macOS)
        .modifier(AgentPasteMonitor(isActive: isFocused, model: model))
        #endif
    }

    /// The caret goes in once the panel is on screen (it may have just appeared or grown), at the
    /// end of the kept draft; once per request (a later click elsewhere keeps its caret).
    private func focusSoon() {
        let request = model.focusRequests
        guard request > handledRequest else { return }
        handledRequest = request
        Task { @MainActor in
            await Task.yield()
            if !isFocused { isFocused = true }
            await Task.yield()
            selection = TextSelection(insertionPoint: model.draft.endIndex)
        }
    }

    /// ↩: sends, or a beep while the message cannot go yet (one is handed over or answered, a
    /// file is still being read).
    private func submit() {
        let hasSomething = hasText || model.hasFiles
        if hasSomething, !model.canSendNow {
            #if os(macOS)
            NSSound.beep()
            #endif
            return
        }
        send()
    }

    /// ⇧↩: a line break at the caret (replacing a selection).
    private func insertLine() {
        let text = model.draft
        var range = text.endIndex..<text.endIndex
        // A selection from before the text last changed may point past its end: the end then.
        if case .selection(let selected)? = selection?.indices, selected.upperBound <= text.endIndex { range = selected }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        var changed = text
        changed.replaceSubrange(range, with: "\n")
        model.draft = changed
        let caret = changed.index(changed.startIndex, offsetBy: offset + 1)
        selection = TextSelection(insertionPoint: caret)
    }

    /// Esc: clears the text and files (Edit ▸ Undo brings them back), then closes the panel.
    private func escape() {
        if !model.draft.isEmpty || model.hasFiles {
            let text = model.draft
            let files = model.attachments
            model.draft = ""
            model.attachments = []
            undoManager?.registerUndo(withTarget: model) { model in
                MainActor.assumeIsolated {
                    model.draft = text
                    model.attachments = files
                }
            }
        } else {
            model.close()
        }
    }
}

/// The open conversation's own sub-agent tasks while queued or running (`AgentTaskLine`); none
/// for a New Chat, and never the app's own background work (triage, document reads, coach
/// drafts: they have no parent conversation).
struct AgentTaskLineSection: View {
    let now: Date
    private let tasksQuery: FetchAll<AgentTask>

    init(conversationID: AgentConversation.ID?, now: Date) {
        self.now = now
        // A New Chat: the nil UUID no row has (the query stays the same across renders).
        let id = conversationID ?? Self.none
        let open = AgentTaskState.open
        tasksQuery = FetchAll(AgentTask.where { $0.parentConversationID.eq(id) && $0.state.in(open) }.order { $0.createdAt.asc() })
    }

    private static let none = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    var body: some View {
        let tasks = tasksQuery.wrappedValue
        if !tasks.isEmpty {
            AgentTaskLine(tasks: tasks, now: now)
                .padding(.bottom, 6)
        }
    }
}

/// While sub-agent tasks are queued or running: one quiet 11.5 pt secondary line above the
/// composer ("2 tasks running", "1 task waiting"); a click lists them, each with Cancel.
struct AgentTaskLine: View {
    let tasks: [AgentTask]
    let now: Date

    @State private var showsList = false

    var body: some View {
        Button {
            showsList.toggle()
        } label: {
            label
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsList, arrowEdge: .top) {
            AgentTaskList(tasks: tasks)
        }
    }

    private var label: Text {
        let running = tasks.filter { $0.state == .running }.count
        if running > 0 {
            return running == 1 ? Text("1 task running") : Text("\(running) tasks running")
        }
        return tasks.count == 1 ? Text("1 task waiting") : Text("\(tasks.count) tasks waiting")
    }
}

/// The open tasks: title, how long it has run (mono), Cancel.
private struct AgentTaskList: View {
    let tasks: [AgentTask]

    @Environment(\.agentPanelActions) private var actions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Hairline() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: task.title)
                            .font(.system(size: 13))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if task.state == .running, let started = task.startedAt {
                            Text(verbatim: TimeText.clock(max(0, timeline.date.timeIntervalSince(started))))
                                .font(.mono(11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button("Cancel") {
                            let actions = actions
                            let id = task.id
                            Task { await actions.cancelTask(id) }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(width: 300)
        }
    }
}
