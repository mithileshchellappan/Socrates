#if os(macOS)
import AppKit

/// What the panes need to know about their window: its width (the room rules), its live resize
/// (`\.isLiveResizing`) and its first responder (`typingPane`, and who loses the keyboard when a
/// pane goes). Watches one window at a time.
@MainActor
final class PaneWindowWatcher {
    var onWidth: (CGFloat) -> Void = { _ in }
    var onLiveResize: (Bool) -> Void = { _ in }
    var onFirstResponder: (NSResponder?) -> Void = { _ in }

    private(set) weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var firstResponder: NSKeyValueObservation?

    func watch(_ window: NSWindow?) {
        guard window !== self.window else { return }
        stop()
        self.window = window
        guard let window else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportWidth() }
            },
            center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLiveResize(true) }
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onLiveResize(false)
                    self?.reportWidth()
                }
            }
        ]
        firstResponder = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reportFirstResponder() }
        }
        reportWidth()
        reportFirstResponder()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        firstResponder?.invalidate()
        firstResponder = nil
        window = nil
    }

    private func reportWidth() {
        guard let window else { return }
        onWidth(window.contentLayoutRect.width)
    }

    private func reportFirstResponder() {
        onFirstResponder(window?.firstResponder)
    }
}
#endif
