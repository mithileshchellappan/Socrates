import Foundation
import os
import StudyCore
import SwiftUI

// `ChatContext` (none, mail, and since M5 lecture, course, search) lives in StudyCore
// (`Values+M5.swift`): Search builds it, the Tutor package reads it, the app routes by it.

/// The answer the agent is writing right now (never stored): its text, to be shown after the
/// first `afterTurns` stored turns of the conversation. Once the conversation has more turns, the
/// answer is stored and this is stale. (The agent runtime's `LiveReply`, mapped by the app.)
public struct ChatLiveReply: Hashable, Sendable {
    public var afterTurns: Int
    public var text: String

    public init(afterTurns: Int, text: String) {
        self.afterTurns = afterTurns
        self.text = text
    }
}

/// What the chat asks the app to do. The chat reads its rows itself (`agent_conversation`,
/// `agent_turn`); the app wires these to `MailChat.send` and the `AgentRuntime`. Defaults do
/// nothing: without them (previews, iOS, no Claude Code) the chat, its toolbar button and its
/// command are absent.
public struct ChatActions: Sendable {
    /// Claude Code is installed and signed in (`ClaudeClient.isAvailable()`, observed by the app).
    /// False: no inspector, no toolbar button, no View ▸ Show Chat.
    public var isAvailable: Bool
    /// A usage limit pauses the AI until then (`ClaudeBackendStatus.pausedUntil`); a failed answer
    /// then reads "Paused until 17:20".
    public var pausedUntil: Date?
    /// Sends the student's words with the screen's context to a conversation (nil: starts a new
    /// one of `context.kind`); returns the conversation's id at once, the answer streams in the
    /// background. M5: the app routes by `context.kind`: `mail_chat` → `MailChat.send`, `tutor` →
    /// `TutorChat.send`.
    public var send: @Sendable (_ text: String, _ context: ChatContext, _ conversation: AgentConversation.ID?) async throws -> AgentConversation.ID
    /// Stops the agent working in a conversation.
    public var stop: @Sendable (AgentConversation.ID) async -> Void
    /// The answer being written in a conversation, about ten times a second (nil: none).
    public var liveReply: @Sendable (AgentConversation.ID) -> AsyncStream<ChatLiveReply?>

    public init(
        isAvailable: Bool = false,
        pausedUntil: Date? = nil,
        send: @escaping @Sendable (String, ChatContext, AgentConversation.ID?) async throws -> AgentConversation.ID = { _, _, _ in
            throw ChatUnavailable()
        },
        stop: @escaping @Sendable (AgentConversation.ID) async -> Void = { _ in },
        liveReply: @escaping @Sendable (AgentConversation.ID) -> AsyncStream<ChatLiveReply?> = { _ in AsyncStream { $0.finish() } }
    ) {
        self.isAvailable = isAvailable
        self.pausedUntil = pausedUntil
        self.send = send
        self.stop = stop
        self.liveReply = liveReply
    }
}

/// A chat action the app has not wired.
public struct ChatUnavailable: Error, Hashable, Sendable {
    public init() {}
}

extension EnvironmentValues {
    /// The chat's actions; the app installs the real ones.
    @Entry public var chatActions = ChatActions()
}

enum ChatUILog {
    /// Never logs the student's words or the agent's text at `.public`.
    static let ui = Log.logger(category: "chat-ui")
}
