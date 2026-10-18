import StudyCore
import StudyUI
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One conversation (or an empty new one): the student's messages as bubbles, the agent's answers
/// as grey text with one sparkle per answer and a chip after each checked citation (M5), the
/// answer being written streaming into place (a skeleton line until its first words), a state
/// line when the last run did not answer, and the composer pinned at the bottom. Never blocks:
/// the composer stays usable while the agent works.
struct ChatPane: View {
    let conversationID: AgentConversation.ID?
    let context: ChatContext
    /// The context a message carries, read at ↩ (Review's playhead); nil: `context`.
    let sendContext: (@MainActor () -> ChatContext)?
    @Binding var draft: String
    @Binding var pending: PendingMessage?
    /// Mirrors the composer's focus for the screen around it.
    let composerFocused: Binding<Bool>?
    /// The conversation the message went to (a new one for the first message of a new chat).
    let started: (AgentConversation.ID) -> Void

    @Environment(\.chatActions) private var actions
    @Environment(\.openDestination) private var openDestination
    @Dependency(\.defaultDatabase) private var database
    @FetchOne private var conversation: AgentConversation?
    @FetchAll private var turns: [AgentTurn]
    @State private var transcript = ChatTranscript()
    @State private var rows = CitationRows()
    @State private var live: ChatLiveReply?
    @State private var isSending = false
    @FocusState private var isComposerFocused: Bool

    init(
        conversationID: AgentConversation.ID?,
        context: ChatContext,
        sendContext: (@MainActor () -> ChatContext)? = nil,
        draft: Binding<String>,
        pending: Binding<PendingMessage?>,
        composerFocused: Binding<Bool>? = nil,
        started: @escaping (AgentConversation.ID) -> Void
    ) {
        self.conversationID = conversationID
        self.context = context
        self.sendContext = sendContext
        _draft = draft
        _pending = pending
        self.composerFocused = composerFocused
        self.started = started
        // A new chat reads nothing (an id no row has).
        let id = conversationID ?? UUID()
        _conversation = FetchOne(AgentConversation.find(id))
        _turns = FetchAll(AgentTurn.where { $0.conversationID.eq(id) }.order(by: \.sequence))
    }

    private var isRunning: Bool { conversation?.state == .running }
    private var isTutor: Bool { context.kind == .tutor }

    /// The lecture on screen (Review's Tutor tab): a chip of another lecture says which one.
    private var openLecture: Lecture.ID? {
        if case .lecture(let id, _, _) = context { return id }
        return nil
    }

    /// The live text belongs after exactly the stored turns it follows, while the run lasts.
    private var liveText: String? {
        guard isRunning, let live, live.afterTurns == transcript.turnCount, !live.text.isEmpty else { return nil }
        return live.text
    }

    private var check: CitationCheck {
        CitationCheck(rows: rows, webPages: transcript.webPages)
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
        .task(id: citesLectures) {
            // The rows lecture markers are checked against, once an answer has one.
            guard citesLectures >= 0 else { return }
            do {
                rows = try await CitationRows.load(database)
            } catch {
                ChatUILog.ui.error("Reading citation rows failed: \(String(describing: error), privacy: .public)")
            }
        }
        .onChange(of: isComposerFocused) { _, focused in
            composerFocused?.wrappedValue = focused
        }
        .environment(\.openURL, OpenURLAction { url in open(url) })
    }

    /// Some answer (or the one being written) has a marker: the rows are read (again when the
    /// conversation grows).
    private var citesLectures: Int {
        let hasMarker = transcript.entries.contains { entry in
            if case .answer(_, let text) = entry { return text.contains("[[") }
            return false
        } || (liveText?.contains("[[") ?? false)
        return hasMarker ? transcript.turnCount : -1
    }

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        let entries = transcript.entries
        let check = check
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            switch entry {
            case .student(_, let text):
                StudentBubble(text: text)
            case .answer(_, let text):
                // The run in progress continues the last answer block.
                let isLast = index == entries.count - 1
                let isWorking = isLast && isRunning
                AnswerBlock(
                    text: isLast ? Self.joined(text, liveText) : text, isWorking: isWorking && liveText == nil, isStreaming: isWorking,
                    check: check, showsCopy: isTutor && !isWorking, openLecture: openLecture
                )
            }
        }
        if let pending {
            StudentBubble(text: pending.text)
        }
        if pending != nil || (isRunning && (transcript.awaitsAnswer || entries.isEmpty)) {
            // The answer's first words, or a skeleton until they come.
            AnswerBlock(text: pending == nil ? liveText ?? "" : "", isWorking: false, isStreaming: true, check: check, showsCopy: false, openLecture: openLecture)
        }
        if let state = stateLine {
            state
        }
    }

    static func joined(_ text: String, _ live: String?) -> String {
        guard let live else { return text }
        return text + "\n\n" + live
    }

    /// A chip: the lecture at its slide or playing from its moment; a web page in the browser
    /// (answers link nothing else: Markdown links are removed).
    private func open(_ url: URL) -> OpenURLAction.Result {
        if let destination = AnswerText.destination(link: url) {
            openDestination(destination)
            return .handled
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return .discarded }
        return .systemAction(url)
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

    /// The prompt: the mail chat's "Ask about your mail"; the tutor's names what it is about until
    /// the first answer, then "Ask a follow-up…" (mockup 07).
    private var prompt: Text {
        switch context {
        case .none, .mail: return Text("Ask about your mail")
        default: break
        }
        if !transcript.entries.isEmpty || pending != nil { return Text("Ask a follow-up…") }
        switch context {
        case .lecture: return Text("Ask about this lecture")
        case .course: return Text("Ask about this course")
        case .search(_, let sources) where !sources.isEmpty: return Text("Ask about the selection")
        default: return Text("Ask about your lectures")
        }
    }

    /// Radius 12 on the content surface with a 0.5 pt ring (mockup 07); ↩ sends, Esc clears; the
    /// send glyph only while there is text, Stop while the agent works.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("", text: $draft, prompt: prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($isComposerFocused)
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
        .onTapGesture { isComposerFocused = true }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, !isSending else { return }
        let actions = actions
        let context = sendContext?() ?? context
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
/// Markdown (bold, italics, code), M5: a chip after each checked citation (slide, moment, web
/// page) and Copy under a finished tutor answer. `isWorking`: a skeleton line follows (no spinner).
private struct AnswerBlock: View {
    let text: String
    let isWorking: Bool
    /// Still being written: a marker not closed yet is left out, and nothing is logged.
    let isStreaming: Bool
    let check: CitationCheck
    let showsCopy: Bool
    let openLecture: Lecture.ID?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if text.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    AIMark()
                    skeleton
                }
            } else {
                let answer = AnswerText(
                    isStreaming ? AnswerText.withoutOpenMarker(text) : text, check: text.contains("[[") ? check : nil, logs: !isStreaming,
                    openLecture: openLecture
                )
                answerText(answer)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isWorking {
                    skeleton
                }
                if showsCopy {
                    Button("Copy") { Self.copy(answer.copyText) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// With chips: one `Text` whose chips are links drawn as capsules (no text selection: Copy
    /// takes the text). Without: selectable text, as before M5.
    @ViewBuilder
    private func answerText(_ answer: AnswerText) -> some View {
        if answer.hasChips {
            answer.text()
                .textRenderer(AnswerChipRenderer(colorScheme: colorScheme))
        } else {
            answer.text()
                .textSelection(.enabled)
        }
    }

    /// The line's final size, redacted, no shimmer.
    private var skeleton: some View {
        Text(verbatim: "The answer is being written for you now")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
    }

    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
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
