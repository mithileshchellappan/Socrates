import Foundation
import StudyCore
import Synchronization

/// The text of the answer the agent is writing right now (M3.5, the chat): the text blocks of the
/// API call in flight, never stored. `agent_turn` keeps only complete turns; once the call's turn
/// is stored, the conversation has more than `afterTurns` turns and this text is stale.
public struct LiveReply: Sendable, Hashable {
    /// The number of stored turns this text follows.
    public var afterTurns: Int
    public var text: String
    /// The run ended without storing this text (stopped, failed, cut off): it is all that will
    /// ever be of that answer, so it stays under the message it answered.
    public var unsaved: Bool

    public init(afterTurns: Int, text: String, unsaved: Bool = false) {
        self.afterTurns = afterTurns
        self.text = text
        self.unsaved = unsaved
    }
}

/// Live replies per conversation, fanned out to every subscriber (each inspector that shows the
/// conversation). A subscriber gets the current reply at once, then every update (at most about
/// ten a second: `TurnRecorder` throttles).
final class LiveReplies: Sendable {
    private struct Entry {
        var reply: LiveReply?
        var subscribers: [UUID: AsyncStream<LiveReply?>.Continuation] = [:]
    }

    private let state = Mutex<[AgentConversation.ID: Entry]>([:])

    func stream(_ id: AgentConversation.ID) -> AsyncStream<LiveReply?> {
        let (stream, continuation) = AsyncStream.makeStream(of: LiveReply?.self, bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        let current = state.withLock { entries -> LiveReply? in
            entries[id, default: Entry()].subscribers[token] = continuation
            return entries[id]?.reply
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            self?.unsubscribe(id, token: token)
        }
        return stream
    }

    func publish(_ id: AgentConversation.ID, _ reply: LiveReply) {
        let subscribers = state.withLock { entries in
            entries[id, default: Entry()].reply = reply
            return entries[id].map { Array($0.subscribers.values) } ?? []
        }
        for subscriber in subscribers { subscriber.yield(reply) }
    }

    /// The run ended: later subscribers get nothing but its unsaved text (a panel opened after a
    /// stopped or failed run still keeps it). Current subscribers keep their last value; the
    /// stored turns and the conversation's state tell them it is over (no flicker between the end
    /// of the stream and the stored turn landing).
    func end(_ id: AgentConversation.ID) {
        state.withLock { entries in
            if entries[id]?.reply?.unsaved != true { entries[id]?.reply = nil }
            if let entry = entries[id], entry.subscribers.isEmpty, entry.reply == nil { entries[id] = nil }
        }
    }

    /// A new run starts: the last run's unsaved text is no longer handed to later subscribers
    /// (Try again answers that message anew).
    func clear(_ id: AgentConversation.ID) {
        state.withLock { entries in
            entries[id]?.reply = nil
            if entries[id]?.subscribers.isEmpty == true { entries[id] = nil }
        }
    }

    private func unsubscribe(_ id: AgentConversation.ID, token: UUID) {
        state.withLock { entries in
            entries[id]?.subscribers[token] = nil
            if let entry = entries[id], entry.subscribers.isEmpty, entry.reply == nil { entries[id] = nil }
        }
    }
}
