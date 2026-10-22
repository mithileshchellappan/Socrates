#if os(macOS)
import AppKit
import SwiftUI

/// ← / → (and Page Up / Page Down) page the slides whenever the review shows them in the key
/// window and no editable text there has the keyboard; a note, the agent panel's composer and the
/// search field keep their arrows. While a pane is maximized over the review (`\.mainIsCovered`)
/// the keys are not the review's.
///
/// A local key monitor decides as each key comes, from the window's first responder: the Review
/// menu's ← / → depend on focus flags, and a flag that went stale (a note's editor that went away
/// with the caret in it: another slide, the other tab, the inspector hidden) or a list that had the
/// keyboard (the sidebar) left the arrows dead or elsewhere. Space stays Play/Pause.
struct ReviewSlideKeys: View {
    let model: ReviewModel
    @Environment(\.mainIsCovered) private var mainIsCovered

    var body: some View {
        SlideKeyAnchor(model: model, isCovered: mainIsCovered)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// Knows the review's window (the monitor acts only on keys for it).
private struct SlideKeyAnchor: NSViewRepresentable {
    let model: ReviewModel
    let isCovered: Bool

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.keys.model = model
        view.keys.isCovered = isCovered
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.keys.model = model
        view.keys.isCovered = isCovered
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.keys.stop()
    }

    final class AnchorView: NSView {
        let keys = SlideKeyMonitor()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            keys.window = window
            if window == nil { keys.stop() } else { keys.start() }
        }
    }
}

/// The local key monitor of `ReviewSlideKeys`, on while its anchor is in a window.
@MainActor
final class SlideKeyMonitor {
    weak var window: NSWindow?
    weak var model: ReviewModel?
    /// A pane is maximized over the review: its keys stand down.
    var isCovered = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
              !isCovered, let model, model.deck != nil,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        else { return false }
        let forward: Bool
        switch event.keyCode {
        case 123, 116: forward = false // ←, Page Up
        case 124, 121: forward = true // →, Page Down
        default: return false
        }
        guard !ReviewTyping.isTyping(in: window) else { return false }
        let session = model.session
        if forward {
            if session.canGoNext { session.nextSlide() }
        } else if session.canGoPrevious {
            session.previousSlide()
        }
        // At the first or last slide the key is still the review's (nothing else moves).
        return true
    }
}

/// Typing in the review's window: an editable text view (a note) or a field's editor (the agent
/// panel's composer, the search field) has the keyboard and is on screen there.
@MainActor
enum ReviewTyping {
    static func isTyping(in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView, textView.isEditable else { return false }
        return textView.window === window && !textView.isHiddenOrHasHiddenAncestor
    }

    /// A click on the review's slide, rail, transcript or player ends typing in its window, so the
    /// review's keys (← / →, Space) are the review's again; never while a character is composed.
    static func endTyping() {
        guard let window = NSApp.keyWindow, isTyping(in: window),
              let textView = window.firstResponder as? NSTextView, !textView.hasMarkedText()
        else { return }
        window.makeFirstResponder(nil)
    }
}

extension View {
    /// A click here ends typing in the window (`ReviewTyping.endTyping`); the click still does
    /// what it does (a thumbnail, a transcript line, the player).
    func endsTypingOnClick() -> some View {
        simultaneousGesture(TapGesture().onEnded { ReviewTyping.endTyping() })
    }
}
#endif
