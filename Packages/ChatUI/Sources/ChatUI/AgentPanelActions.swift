import Foundation
import StudyCore
import SwiftUI

// The agent panel's hooks (ma, docs/plan-agent.md §5.2, §6): what the panel asks the app to do,
// and what a window may open it with (renders). The panel reads its rows itself
// (`agent_conversation` of kind `app`, `agent_turn` with its `context`, `agent_task`,
// `agent_change`); every effect goes through `AgentPanelActions`, which the app wires to AppAgent.

/// What the agent panel asks the app to do. Defaults do nothing: without them (previews, iOS, no
/// Claude Code) the panel, its launcher and its menu items are absent.
public struct AgentPanelActions: Sendable {
    /// Claude Code is installed and signed in. False: no panel, no launcher, no View ▸ Show Chat.
    public var isAvailable: Bool
    /// A usage limit pauses the AI until then; a failed answer then reads "Paused until 17:20".
    public var pausedUntil: Date?
    /// Sends the student's words (possibly empty when files go alone) with the context at ↩ and
    /// the attached files (stored in the BlobStore already) to a conversation of kind `app` (nil:
    /// a new one); returns the conversation's id at once, the answer streams in the background.
    public var send: @Sendable (_ text: String, _ context: AgentContext, _ attachments: [AgentAttachment], _ conversation: AgentConversation.ID?) async throws -> AgentConversation.ID
    /// Stops the agent working in a conversation.
    public var stop: @Sendable (AgentConversation.ID) async -> Void
    /// The answer being written in a conversation, about ten times a second (nil: none).
    public var liveReply: @Sendable (AgentConversation.ID) -> AsyncStream<ChatLiveReply?>
    /// Cancels a queued or running sub-agent task (the task line's Cancel).
    public var cancelTask: @Sendable (AgentTask.ID) async -> Void
    /// Undoes an automatic change (a change row's popover Undo).
    public var undoChange: @Sendable (AgentChange.ID) async throws -> Void
    /// Answers a conversation's last message again after its run failed ("Try again"; nil: no
    /// button, the phone's relay).
    public var retry: (@Sendable (AgentConversation.ID) async throws -> Void)?
    /// The faint context line a message sent now would carry (the screen's glyph and label), for
    /// the pending bubble before its stored turn has it; nil: none.
    public var contextLine: (@Sendable (AgentContext) async -> AgentContextLine?)?

    public init(
        isAvailable: Bool = false,
        pausedUntil: Date? = nil,
        send: @escaping @Sendable (String, AgentContext, [AgentAttachment], AgentConversation.ID?) async throws -> AgentConversation.ID = { _, _, _, _ in
            throw ChatUnavailable()
        },
        stop: @escaping @Sendable (AgentConversation.ID) async -> Void = { _ in },
        liveReply: @escaping @Sendable (AgentConversation.ID) -> AsyncStream<ChatLiveReply?> = { _ in AsyncStream { $0.finish() } },
        cancelTask: @escaping @Sendable (AgentTask.ID) async -> Void = { _ in },
        undoChange: @escaping @Sendable (AgentChange.ID) async throws -> Void = { _ in throw ChatUnavailable() },
        retry: (@Sendable (AgentConversation.ID) async throws -> Void)? = nil,
        contextLine: (@Sendable (AgentContext) async -> AgentContextLine?)? = nil
    ) {
        self.isAvailable = isAvailable
        self.pausedUntil = pausedUntil
        self.send = send
        self.stop = stop
        self.liveReply = liveReply
        self.cancelTask = cancelTask
        self.undoChange = undoChange
        self.retry = retry
        self.contextLine = contextLine
    }
}

/// A context line's glyph and label ("waveform" · "DC Lecture 2").
public struct AgentContextLine: Hashable, Sendable {
    public var glyph: String
    public var label: String

    public init(glyph: String, label: String) {
        self.glyph = glyph
        self.label = label
    }
}

/// Why a message did not go, as the panel's notice line says it: one readable sentence ("Claude
/// Code is signed out.", "Lecture3.pdf could not be read."), never an error's own text.
public struct AgentSendFailure: LocalizedError, Sendable {
    public var sentence: String

    public init(sentence: String) {
        self.sentence = sentence
    }

    public var errorDescription: String? { sentence }
}

extension EnvironmentValues {
    /// The agent panel's actions; the app installs the real ones on the main window.
    @Entry public var agentPanelActions = AgentPanelActions()
    /// The agent panel's composer has keyboard focus. `.agentPanel` sets it for the window's
    /// content (and folds it into `\.isSearchFieldFocused`), so a screen's plain keys stand down
    /// while the student types to the agent (Review reads it in `ReviewActions.isEditingText`).
    @Entry public var isAgentComposerFocused = false
}

/// How a window's panel starts (the app's renders: `ParityMode.Launch.panel`). The default is
/// closed, on the newest conversation.
public struct AgentPanelLaunch: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        case closed
        /// The floating panel.
        case compact
        /// The full-height trailing column.
        case expanded
    }

    public var mode: Mode
    /// The conversation shown; nil: the newest `app` conversation.
    public var conversationID: AgentConversation.ID?
    /// An empty New Chat instead of a conversation.
    public var newChat: Bool
    /// Renders only: the conversation's exchanges shown (0-based, a student message with its
    /// answer; with the task results that came after them), as mockup §1–2 draw one. Nil (the
    /// app): the whole conversation, as every panel and sheet shows it.
    public var exchanges: Range<Int>?
    /// Text in the composer.
    public var draft: String
    /// Files in the composer (already in the BlobStore, e.g. a seeded turn's attachments).
    public var attachments: [AgentAttachment]
    /// Renders only: a message just sent and not stored yet (its bubble and the skeleton line
    /// after the conversation's exchanges; the prompt reads "Ask a follow-up…").
    public var pendingText: String?
    /// A fixed "now" (the history menu's days, a task's elapsed time); nil follows the clock.
    public var now: Date?

    public init(
        mode: Mode = .closed,
        conversationID: AgentConversation.ID? = nil,
        newChat: Bool = false,
        exchanges: Range<Int>? = nil,
        draft: String = "",
        attachments: [AgentAttachment] = [],
        pendingText: String? = nil,
        now: Date? = nil
    ) {
        self.mode = mode
        self.conversationID = conversationID
        self.newChat = newChat
        self.exchanges = exchanges
        self.draft = draft
        self.attachments = attachments
        self.pendingText = pendingText
        self.now = now
    }
}
