import Foundation
import Observation
import StudyCore
import StudyUI

/// The "New deadline" composer's state (docs/DESIGN.md §8.3): the typed text, its local parse
/// (previewed dashed in the grid, never blocking the field) and, after ↩ handed the text to the
/// agent, the parse kept on screen while that conversation runs.
@MainActor
@Observable
final class ComposerModel {
    var text: String
    /// The local parse of `text` (`DeadlineActions.preview`).
    private(set) var livePreview: DeadlineDraft?
    /// The parse of the text the agent is working on (`.agent(id)`), while it runs.
    private(set) var agentPreview: DeadlineDraft?
    /// The conversation the composer waits for.
    private(set) var conversationID: AgentConversation.ID?
    private(set) var isSubmitting = false

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// The text `livePreview` belongs to.
    @ObservationIgnored private var previewedText = ""

    /// How long typing rests before the text is parsed.
    static let debounce: Duration = .milliseconds(150)

    init(text: String = "") {
        self.text = text
    }

    /// What the grid draws dashed.
    var shownPreview: DeadlineDraft? { livePreview ?? agentPreview }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The text changed: parse it after a short rest. Empty text clears the preview at once.
    func textChanged(actions: DeadlineActions, now: Date) {
        previewTask?.cancel()
        let text = text
        guard hasText else {
            livePreview = nil
            previewedText = ""
            return
        }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.updatePreview(for: text, actions: actions, now: now)
        }
    }

    /// Parses `text` now (the debounced step; tests call it directly).
    func updatePreview(for text: String, actions: DeadlineActions, now: Date) async {
        let draft = await actions.preview(text, now)
        // A parse that lands after the text moved on is dropped.
        guard text == self.text else { return }
        livePreview = draft
        previewedText = text
    }

    /// ↩ or the send glyph: `.added` and `.agent` clear the field (`.agent` keeps the preview
    /// while its conversation runs); `.notUnderstood` and failures keep the text.
    func submit(actions: DeadlineActions, now: Date) async {
        guard hasText, !isSubmitting else { return }
        let text = text
        isSubmitting = true
        defer { isSubmitting = false }
        previewTask?.cancel()
        let preview = previewedText == text ? livePreview : await actions.preview(text, now)
        let result: DeadlineSubmission
        do {
            result = try await actions.submit(text, now)
        } catch {
            CalendarUILog.ui.error("Submitting a deadline failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        switch result {
        case .added:
            clearField()
        case .agent(let id):
            clearField()
            conversationID = id
            agentPreview = preview
        case .notUnderstood:
            break
        }
    }

    /// The conversation the composer waits for changed state: the kept preview goes once it
    /// is no longer running (what the agent wrote is in the rows by then).
    func conversationChanged(_ state: ConversationState?) {
        guard let state, state != .running else { return }
        conversationID = nil
        agentPreview = nil
    }

    /// Esc.
    func clear() {
        previewTask?.cancel()
        clearField()
    }

    private func clearField() {
        text = ""
        livePreview = nil
        previewedText = ""
    }
}
