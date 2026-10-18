import StudyUI
import SwiftUI

/// What the practice round or practice exam on screen can do from the keyboard (DESIGN §6.8's
/// command pattern): nil closures are not offered. Plain keys (1–4, Space, →) attach only while
/// nothing is being typed; ⌘ keys only while the screen is focused.
public struct PracticeActions {
    /// A text field has focus (the answer field, the search field, the agent's composer).
    public var isEditingText: Bool
    /// 1–4: pick a choice (0-based index).
    public var pick: (@MainActor (Int) -> Void)?
    /// Space: play the professor's sentence (a round, after the answer).
    public var playSentence: (@MainActor () -> Void)?
    /// →: the next question (a round, after the answer).
    public var next: (@MainActor () -> Void)?
    /// ⌘↩: hand in the written answer (a round).
    public var submitAnswer: (@MainActor () -> Void)?
    /// End (a round).
    public var end: (@MainActor () -> Void)?
    /// ⇧⌘L: flag the question (an exam).
    public var toggleFlag: (@MainActor () -> Void)?
    public var isFlagged = false
    /// ⇧⌘[ / ⇧⌘]: the previous / next question (an exam).
    public var previousQuestion: (@MainActor () -> Void)?
    public var nextQuestion: (@MainActor () -> Void)?
    /// Pause / Resume (an exam).
    public var pauseOrResume: (@MainActor () -> Void)?
    public var isPaused = false
    /// Submit (an exam).
    public var submitExam: (@MainActor () -> Void)?

    public init(isEditingText: Bool) {
        self.isEditingText = isEditingText
    }
}

extension FocusedValues {
    /// The practice round or exam in the key window, if any.
    @Entry public var practiceActions: PracticeActions?
}

/// The Practice menu: Choice 1–4 (1–4), Play Sentence (Space), Next Question (→), Submit Answer
/// (⌘↩), End; in an exam Flag (⇧⌘L), Previous / Next Question (⇧⌘[ / ⇧⌘]), Pause / Resume,
/// Submit. Install it once in the app's commands:
///
///     WindowGroup { … }.commands { PracticeCommands() }
public struct PracticeCommands: Commands {
    @FocusedValue(\.practiceActions) private var actions

    public init() {}

    public var body: some Commands {
        let keys = actions.map { !$0.isEditingText } ?? false
        let focused = actions != nil
        CommandMenu("Practice") {
            ForEach(1...4, id: \.self) { number in
                Button("Choice \(number)") { actions?.pick?(number - 1) }
                    .keyboardShortcut(keys && actions?.pick != nil ? KeyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: []) : nil)
                    .disabled(actions?.pick == nil || !keys)
            }
            Divider()
            Button("Play Sentence") { actions?.playSentence?() }
                .keyboardShortcut(keys && actions?.playSentence != nil ? KeyboardShortcut(.space, modifiers: []) : nil)
                .disabled(actions?.playSentence == nil || !keys)
            Button("Submit Answer") { actions?.submitAnswer?() }
                .keyboardShortcut(focused && actions?.submitAnswer != nil ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
                .disabled(actions?.submitAnswer == nil)
            Button("Next Question") { (actions?.next ?? actions?.nextQuestion)?() }
                .keyboardShortcut(nextShortcut(keys: keys, focused: focused))
                .disabled(actions?.next == nil && actions?.nextQuestion == nil)
            Button("Previous Question") { actions?.previousQuestion?() }
                .keyboardShortcut(focused && actions?.previousQuestion != nil ? KeyboardShortcut("[", modifiers: [.command, .shift]) : nil)
                .disabled(actions?.previousQuestion == nil)
            Divider()
            Button(actions?.isFlagged == true ? "Unflag" : "Flag") { actions?.toggleFlag?() }
                .keyboardShortcut(focused && actions?.toggleFlag != nil ? KeyboardShortcut("l", modifiers: [.command, .shift]) : nil)
                .disabled(actions?.toggleFlag == nil)
            Button(actions?.isPaused == true ? "Resume" : "Pause") { actions?.pauseOrResume?() }
                .disabled(actions?.pauseOrResume == nil)
            Button("Submit") { actions?.submitExam?() }
                .disabled(actions?.submitExam == nil)
            Button("End") { actions?.end?() }
                .disabled(actions?.end == nil)
        }
    }

    /// → in a round (after the answer, while nothing is typed); ⇧⌘] in an exam.
    private func nextShortcut(keys: Bool, focused: Bool) -> KeyboardShortcut? {
        if actions?.next != nil { return keys ? KeyboardShortcut(.rightArrow, modifiers: []) : nil }
        if actions?.nextQuestion != nil, focused { return KeyboardShortcut("]", modifiers: [.command, .shift]) }
        return nil
    }
}

/// Publishes a screen's `PracticeActions` from a tiny view (the command pattern's publisher).
struct PracticeActionsPublisher: View {
    let actions: PracticeActions

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .focusedSceneValue(\.practiceActions, actions)
    }
}
