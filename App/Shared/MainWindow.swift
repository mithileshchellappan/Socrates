import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The library window (`WindowGroup(id: MainWindow.id)`), seen from other windows.
enum MainWindow {
    static let id = "main"

    #if os(macOS)
    /// The library windows open now (`MainWindowReader` registers them).
    @MainActor private static let windows = NSHashTable<NSWindow>.weakObjects()

    @MainActor
    static func register(_ window: NSWindow) {
        windows.add(window)
    }

    /// Brings the library window forward (the live lecture window's sidebar button), or opens one
    /// when none is open.
    @MainActor
    static func bringForward(openWindow: OpenWindowAction) {
        let open = windows.allObjects.filter { $0.isVisible || $0.isMiniaturized }
        guard let window = open.first(where: \.isVisible) ?? open.first else {
            openWindow(id: id)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
    #endif
}

#if os(macOS)
/// Registers the library window it is in with `MainWindow`.
struct MainWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindow.register(window) }
        }
    }
}
#endif
