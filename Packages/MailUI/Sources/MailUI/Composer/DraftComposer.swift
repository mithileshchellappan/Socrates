import StudyCore
import StudyUI
import SwiftUI

/// The open draft replying to a message (the reader's inline reply), or one draft by id (a new
/// message), when it is open (generating, draft, failed, sending).
struct DraftSlot: View {
    private let draftsQuery: FetchAll<MailDraft>
    @Environment(\.mailActions) private var actions
    @Environment(\.studyServices) private var services

    private static let open: [MailDraftState] = [.generating, .draft, .failed, .sending]

    init(replyingTo messageID: MailMessage.ID, database: (any DatabaseReader)? = nil) {
        let open = Self.open
        draftsQuery = FetchAll(
            MailDraft.where { $0.mailMessageID.eq(messageID) && $0.state.in(open) }.order { $0.updatedAt.desc() },
            database: database
        )
    }

    init(draftID: MailDraft.ID, database: (any DatabaseReader)? = nil) {
        let open = Self.open
        draftsQuery = FetchAll(MailDraft.where { $0.id.eq(draftID) && $0.state.in(open) }, database: database)
    }

    var body: some View {
        if let draft = draftsQuery.wrappedValue.first {
            DraftComposer(draft: draft, actions: actions, services: services)
                .id(draft.id)
        }
    }
}

/// The reply box of mockup 05: To tokens, the editor (the agent's unchanged words grey with one
/// sparkle, the student's primary), Discard and Send (the screen's one filled button, ⇧⌘D from
/// the Message menu). A new message adds a Subject field and has no agent.
struct DraftComposer: View {
    let draft: MailDraft
    @State private var model: DraftEditorModel
    @Environment(\.mailFocus) private var focus

    init(draft: MailDraft, actions: MailActions, services: StudyServices?) {
        self.draft = draft
        _model = State(initialValue: DraftEditorModel(draft: draft, actions: actions, services: services))
    }

    var body: some View {
        ComposerBox(model: model, focus: focus)
            .onChange(of: draft) { _, draft in model.update(from: draft) }
            .onDisappear {
                let model = model
                Task { await model.flush() }
            }
    }
}

/// What the Message menu's Send does: the composer on screen.
@MainActor
struct MailComposerCommands {
    var canSend: Bool
    var send: () -> Void
}

extension FocusedValues {
    @Entry var mailComposer: MailComposerCommands?
}

extension EnvironmentValues {
    @Entry var mailFocus: MailFocus?
}

private struct ComposerBox: View {
    let model: DraftEditorModel
    let focus: MailFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: model.isReply ? "arrowshape.turn.up.left" : "envelope")
                    .foregroundStyle(.secondary)
                RecipientField(addresses: model.to, isEditable: model.canEdit) { model.setHeaders(to: $0) }
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Divider() }

            if !model.isReply {
                TextField(
                    "Subject",
                    text: Binding(get: { model.subject }, set: { model.setHeaders(subject: $0) }),
                    prompt: Text("Subject")
                )
                .textFieldStyle(.plain)
                .fontWeight(.semibold)
                .labelsHidden()
                .disabled(!model.canEdit)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { Divider() }
            }

            ZStack(alignment: .topLeading) {
                DraftTextView(
                    text: model.text,
                    generated: model.generated,
                    isEditable: model.canEdit,
                    leadingIndent: model.showsAgentMark ? 18 : 0,
                    wantsFocus: focus?.editorRequest == model.draftID,
                    onEdit: { model.edit($0) },
                    onFocusChange: { focused in
                        focus?.isEditingText = focused
                        if focused, focus?.editorRequest == model.draftID { focus?.editorRequest = nil }
                    }
                )
                if model.showsAgentMark {
                    AIMark()
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 6) {
                if let error = model.errorText {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Discard") {
                    Task { await model.discard() }
                }
                .buttonStyle(.bordered)
                .disabled(model.state == .sending || model.isSending)
                Button {
                    Task { await model.send() }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
            }
        }
        .padding(.top, 9)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .focusedSceneValue(\.mailComposer, MailComposerCommands(canSend: model.canSend) {
            Task { await model.send() }
        })
    }
}

/// Recipients as tokens; while editable, a field after them takes more ("Name <a@b>", "a@b",
/// committed with ↩, a comma or leaving the field).
struct RecipientField: View {
    let addresses: [MailAddress]
    let isEditable: Bool
    let onChange: ([MailAddress]) -> Void

    @State private var entry = ""
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 4) {
            ForEach(Array(addresses.enumerated()), id: \.offset) { index, address in
                Text(address.displayName)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        .tint.opacity(colorScheme == .dark ? 0.24 : 0.12),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .help(address.address)
                    .contextMenu {
                        if isEditable {
                            Button("Remove") { remove(at: index) }
                        }
                    }
            }
            if isEditable {
                // macOS shows a nil prompt's title as the placeholder: an empty one after tokens.
                TextField("To", text: $entry, prompt: addresses.isEmpty ? Text("To") : Text(verbatim: ""))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($isFocused)
                    .frame(minWidth: 140)
                    .onSubmit(commit)
                    .onChange(of: entry) { _, text in
                        if text.contains(",") || text.contains(";") { commit() }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commit() {
        let added = MailText.addresses(from: entry)
        guard !added.isEmpty else { return }
        let known = Set(addresses.map(\.normalizedAddress))
        onChange(addresses + added.filter { !known.contains($0.normalizedAddress) })
        entry = ""
    }

    private func remove(at index: Int) {
        guard addresses.indices.contains(index) else { return }
        var remaining = addresses
        remaining.remove(at: index)
        onChange(remaining)
    }
}
