import Capture
import SwiftUI

/// What the live-lecture screen can do right now, published as a focused scene value so menu
/// commands (→, Space, ←, F) can drive it. Slide keys are disabled while a text field has
/// focus, so typing a note never stamps a slide.
public struct LiveLectureActions {
    public var canGoNext: Bool
    public var canGoPrevious: Bool
    public var canFlag: Bool
    public var isRecording: Bool
    public var canRecord: Bool
    /// A text field (quick note, flag text) has focus.
    public var isEditingText: Bool

    public var next: () -> Void
    public var previous: () -> Void
    public var flag: () -> Void
    /// Starts recording, or asks to stop when recording.
    public var toggleRecording: () -> Void

    public init(
        canGoNext: Bool,
        canGoPrevious: Bool,
        canFlag: Bool,
        isRecording: Bool,
        canRecord: Bool,
        isEditingText: Bool,
        next: @escaping () -> Void,
        previous: @escaping () -> Void,
        flag: @escaping () -> Void,
        toggleRecording: @escaping () -> Void
    ) {
        self.canGoNext = canGoNext
        self.canGoPrevious = canGoPrevious
        self.canFlag = canFlag
        self.isRecording = isRecording
        self.canRecord = canRecord
        self.isEditingText = isEditingText
        self.next = next
        self.previous = previous
        self.flag = flag
        self.toggleRecording = toggleRecording
    }

    public var nextEnabled: Bool { canGoNext && !isEditingText }
    public var previousEnabled: Bool { canGoPrevious && !isEditingText }
    public var flagEnabled: Bool { canFlag && !isEditingText }
}

extension FocusedValues {
    /// The live-lecture screen in the key window, if any.
    @Entry public var liveLecture: LiveLectureActions?
}

/// Menu commands for live lectures: → or Space next slide, ← previous slide, F flag, Record/Stop.
/// A menu item has one shortcut, so Next Slide is listed once per key (as Safari lists its tab
/// shortcuts). Menu key equivalents run before the focused view sees the key, so the screen's own
/// Space handler never fires for the same press.
///
///     WindowGroup { … }.commands { LiveLectureCommands() }
///
/// ln: the app puts the lecture notes' Ask… and Highlight at the menu's top (`leading`), so the
/// Lecture menu stays one menu. link: the iPhone's recording follows Record (`trailing`; the items
/// bring their own divider and show only while there is something to control).
public struct LiveLectureCommands<Leading: View, Trailing: View>: Commands {
    @FocusedValue(\.liveLecture) private var live
    private let leading: Leading
    private let trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some Commands {
        // A menu item with a key equivalent takes the key even while disabled, so the plain keys
        // are attached only while the live screen is in the key window and no text field has
        // focus (typing a note, or anywhere in the main window, never loses a keystroke), and
        // Record's ⇧⌘R only while the live screen is focused (Review ▸ Mark as Reviewed has it in
        // the main window).
        let keys = live.map { !$0.isEditingText } ?? false
        CommandMenu("Lecture") {
            leading
            Button("Next Slide") { live?.next() }
                .keyboardShortcut(keys ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
                .disabled(live?.nextEnabled != true)
            Button("Next Slide") { live?.next() }
                .keyboardShortcut(keys ? KeyboardShortcut(.space, modifiers: []) : nil)
                .disabled(live?.nextEnabled != true)
            Button("Previous Slide") { live?.previous() }
                .keyboardShortcut(keys ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
                .disabled(live?.previousEnabled != true)
            Button("Flag") { live?.flag() }
                .keyboardShortcut(keys ? KeyboardShortcut("f", modifiers: []) : nil)
                .disabled(live?.flagEnabled != true)
            Divider()
            Button(live?.isRecording == true ? "Stop Recording" : "Record") { live?.toggleRecording() }
                .keyboardShortcut(live != nil ? KeyboardShortcut("r", modifiers: [.command, .shift]) : nil)
                .disabled(live == nil || (live?.isRecording != true && live?.canRecord != true))
            trailing
        }
    }
}

extension LiveLectureCommands where Trailing == EmptyView {
    public init(@ViewBuilder leading: () -> Leading) {
        self.init(leading: leading) { EmptyView() }
    }
}

extension LiveLectureCommands where Leading == EmptyView, Trailing == EmptyView {
    public init() {
        self.init { EmptyView() }
    }
}
