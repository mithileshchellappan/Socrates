import StudyCore
import StudyUI
import SwiftUI

/// One conversation (or an empty new one): the student's messages as bubbles, the agent's answers
/// as grey text with one sparkle per answer, the answer being written streaming into place (a
/// skeleton line until its first words), a state line when the last run did not answer, and the
/// composer pinned at the bottom. Never blocks: the composer stays usable while the agent works.
struct ChatPane: View {
    let conversationID: AgentConversation.ID?
    let context: ChatContext
    @Binding var draft: String
    @Binding var pending: PendingMessage?
    /// The conversation the message went to (a new one for the first message of a new chat).
    let started: (AgentConversation.ID) -> Void

    @Environment(\.chatActions) private var actions
    @FetchOne private var conversation: AgentConversation?
    @FetchAll private var turns: [AgentTurn]
    @State private var transcript = ChatTranscript()
    @State private var live: ChatLiveReply?
    @State private var isSending = false
    @FocusState private var composerFocused: Bool

    init(
        conversationID: AgentConversation.ID?,
        context: ChatContext,
        draft: Binding<String>,
        pending: Binding<PendingMessage?>,
        started: @escaping (AgentConversation.ID) -> Void
    ) {
        self.conversationID = conversationID
        self.context = context
        _draft = draft
        _pending = pending
        self.started = started
        // A new chat reads nothing (an id no row has).
        let id = conversationID ?? UUID()
        _conversation = FetchOne(AgentConversation.find(id))
        _turns = FetchAll(AgentTurn.where { $0.conversationID.eq(id) }.order(by: \.sequence))
    }

    private var isRunning: Bool { conversation?.state == .running }

    /// The live text belongs after exactly the stored turns it follows, while the run lasts.
    private var liveText: String? {
        guard isRunning, let live, live.afterTurns == transcript.turnCount, !live.text.isEmpty else { return nil }
        return live.text
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    messages
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollIndicators(.automatic)
            composer
        }
        .onChange(of: turns, initial: true) { _, turns in
            transcript = ChatTranscript(turns: turns)
            if let sent = pending, transcript.turnCount > sent.afterTurns { pending = nil }
        }
        .task(id: conversationID) {
            guard let conversationID else { return }
            for await reply in actions.liveReply(conversationID) {
                live = reply
            }
        }
    }

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        let entries = transcript.entries
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            switch entry {
            case .student(_, let text):
                StudentBubble(text: text)
            case .answer(_, let text):
                // The run in progress continues the last answer block.
                let isLast = index == entries.count - 1
                AnswerBlock(text: isLast ? Self.joined(text, liveText) : text, isWorking: isLast && isRunning && liveText == nil)
            }
        }
        if let pending {
            StudentBubble(text: pending.text)
        }
        if pending != nil || (isRunning && (transcript.awaitsAnswer || entries.isEmpty)) {
            // The answer's first words, or a skeleton until they come.
            AnswerBlock(text: pending == nil ? liveText ?? "" : "", isWorking: false)
        }
        if let state = stateLine {
            state
        }
    }

    static func joined(_ text: String, _ live: String?) -> String {
        guard let live else { return text }
        return text + "\n\n" + live
    }

    /// Why the last message has no answer: a usage pause ("Paused until 17:20"), or "Not answered"
    /// with the reason on hover. A run the student stopped needs no line.
    private var stateLine: AnyView? {
        guard let conversation, conversation.state == .failed, pending == nil else { return nil }
        let error = conversation.error ?? ""
        // `AgentRuntime` stores "Stopped." for a run the student stopped.
        guard error != "Stopped." else { return nil }
        if let until = actions.pausedUntil, until > Date() {
            let time = Text(DayText.time(until, timeZone: .current)).font(.mono(12))
            return AnyView(
                Text("Paused until \(time)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            )
        }
        return AnyView(
            Label("Not answered", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help(Text(verbatim: error))
        )
    }

    // MARK: Composer

    /// Radius 12 on the content surface with a 0.5 pt ring (mockup 07); ↩ sends, Esc clears; the
    /// send glyph only while there is text, Stop while the agent works.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("", text: $draft, prompt: Text("Ask about your mail"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit(send)
                .onKeyPress(.escape) {
                    guard !draft.isEmpty else { return .ignored }
                    draft = ""
                    return .handled
                }
                .padding(.vertical, 3)
            if isRunning, let conversationID {
                Button {
                    Task { await actions.stop(conversationID) }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Stop"))
                .help(Text("Stop"))
            } else if hasText {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Send"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .background(Color.contentBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = true }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, !isSending else { return }
        let actions = actions
        let context = context
        let conversationID = conversationID
        draft = ""
        pending = PendingMessage(text: text, afterTurns: conversationID == nil ? 0 : transcript.turnCount)
        isSending = true
        Task {
            do {
                let id = try await actions.send(text, context, conversationID)
                started(id)
            } catch {
                ChatUILog.ui.error("Sending a chat message failed: \(String(describing: error), privacy: .public)")
                if draft.isEmpty { draft = text }
                pending = nil
            }
            isSending = false
        }
    }
}

/// The student's message: a bubble on Fill 2, radius 14/14/4/14, at most 264 wide, trailing.
private struct StudentBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .background(
                Fill2(),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14,
                    style: .continuous
                )
            )
            .frame(maxWidth: 264, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The agent's answer: grey (`.secondary`) 13 pt text with one sparkle at its start, inline
/// Markdown (bold, italics, code). `isWorking`: a skeleton line follows (no spinner).
private struct AnswerBlock: View {
    let text: String
    let isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if text.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    AIMark()
                    skeleton
                }
            } else {
                Text("\(Text(Image(systemName: "sparkle")).foregroundStyle(Color.ai)) \(Text(Self.attributed(text)))")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if isWorking {
                    skeleton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line's final size, redacted, no shimmer.
    private var skeleton: some View {
        Text(verbatim: "The answer is being written for you now")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Fill 2 (`--fill2`): rgb(120,120,128) at 17 % light, 30 % dark: the student's chat bubble
/// (docs/DESIGN.md §3.1; promote it into StudyUI beside `QuietFill` on its second use).
struct Fill2: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255)
            .opacity(environment.colorScheme == .dark ? 0.30 : 0.17)
            .resolve(in: environment)
    }
}
