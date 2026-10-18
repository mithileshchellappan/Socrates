import StudyCore
import StudyUI
import SwiftUI

/// The panel's composer (DESIGN 8.6, mockup §1, §4): the files waiting as tiles, then [paperclip |
/// the field | Send or Stop] on the content surface, radius 12, a 0.5 pt ring. The prompt names
/// what the next message is about. Send (`arrow.up.circle`, accent outline) appears with text or a
/// file; Stop while the agent works. ↩ sends, ⌥↩ adds a line, ⌘V pastes a file or screenshot, Esc
/// clears and then closes the panel.
struct AgentComposer: View {
    let model: AgentPanelModel
    let prompt: Text
    let conversationID: AgentConversation.ID?
    let send: () -> Void

    @Environment(\.agentPanelActions) private var actions
    @Environment(\.studyServices) private var services
    @FocusState private var isFocused: Bool
    @State private var showsImporter = false

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
                TextField("", text: $model.draft, prompt: prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .onSubmit(send)
                    .onKeyPress(.escape) {
                        escape()
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
        .background(Color.contentBackground, in: shape)
        .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
        .contentShape(shape)
        .onTapGesture { isFocused = true }
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

    /// The caret goes in once the panel is on screen (it may have just appeared or grown).
    private func focusSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            isFocused = true
        }
    }

    /// Esc: clears the text and files, then closes the panel.
    private func escape() {
        if !model.draft.isEmpty || model.hasFiles {
            model.draft = ""
            model.attachments = []
        } else {
            model.close()
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
