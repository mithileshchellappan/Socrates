import Foundation
import os
import StudyCore
import SwiftUI

/// The answer the agent is writing right now (never stored): its text, to be shown after the
/// first `afterTurns` stored turns of the conversation. Once the conversation has more turns, the
/// answer is stored and this is stale. (The agent runtime's `LiveReply`, mapped by the app.)
public struct ChatLiveReply: Hashable, Sendable {
    public var afterTurns: Int
    public var text: String
    /// The run ended without storing this text (stopped, failed, cut off): the thread keeps it
    /// under the message it answered.
    public var isUnsaved: Bool

    public init(afterTurns: Int, text: String, isUnsaved: Bool = false) {
        self.afterTurns = afterTurns
        self.text = text
        self.isUnsaved = isUnsaved
    }
}

/// A panel action the app has not wired.
public struct ChatUnavailable: Error, Hashable, Sendable {
    public init() {}
}

enum ChatUILog {
    /// Never logs the student's words or the agent's text at `.public`.
    static let ui = Log.logger(category: "chat-ui")
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
