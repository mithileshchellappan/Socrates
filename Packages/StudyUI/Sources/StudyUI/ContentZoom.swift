import SwiftUI

// nl (docs/plan-notes-layout.md §11): content zoom "like Word". View ▸ Actual Size (⌘0), Zoom In
// (⌘+, also ⌘=) and Zoom Out (⌘−) scale the reading and writing CONTENT of the course screens (the
// lecture notes page and Review's Whole lecture, the Your notes column, the note editor, Review's
// transcript and inspector text, the course's Lectures list), never the sidebar, toolbar, buttons
// or other chrome. One value for the whole app, kept in UserDefaults. Mac only: on iOS the scale
// stays 1 and nothing is published.
//
// A screen with zoomable content applies `.contentZoomable()` ONCE at its root; its content views
// read `\.contentZoom` and multiply their point sizes (fonts, line heights, text-relative figure
// sizes and caps) by it. The app adds `ContentZoomCommands()` to its scene's commands.

/// The zoom steps and the stored value.
public enum ContentZoom {
    /// The one stored value (a `Double`, 1 = 100 %).
    public static let defaultsKey = "Socrates.contentZoom"
    /// 75, 85, 100, 115, 130, 150, 175, 200 %.
    public static let steps: [Double] = [0.75, 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]

    /// `scale` on its nearest step (a value from elsewhere, 0 or not a number: 100 %).
    public static func step(_ scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return 1 }
        return steps.min { abs($0 - scale) < abs($1 - scale) } ?? 1
    }

    /// The next step up; nil at 200 %.
    public static func zoomedIn(from scale: Double) -> Double? {
        let current = step(scale)
        return steps.first { $0 > current + 0.001 }
    }

    /// The next step down; nil at 75 %.
    public static func zoomedOut(from scale: Double) -> Double? {
        let current = step(scale)
        return steps.last { $0 < current - 0.001 }
    }
}

/// What the View menu's zoom items act on: published by `.contentZoomable()` while a screen with
/// zoomable content shows in the key window (nil elsewhere: the items are off and their keys free).
public struct ContentZoomControl: Sendable {
    /// The current scale, on a step.
    public let scale: Double
    private let set: @MainActor @Sendable (Double) -> Void

    public init(scale: Double, set: @escaping @MainActor @Sendable (Double) -> Void) {
        self.scale = ContentZoom.step(scale)
        self.set = set
    }

    public var canZoomIn: Bool { ContentZoom.zoomedIn(from: scale) != nil }
    public var canZoomOut: Bool { ContentZoom.zoomedOut(from: scale) != nil }
    public var isActualSize: Bool { scale == 1 }

    @MainActor
    public func zoomIn() {
        if let next = ContentZoom.zoomedIn(from: scale) { set(next) }
    }

    @MainActor
    public func zoomOut() {
        if let next = ContentZoom.zoomedOut(from: scale) { set(next) }
    }

    @MainActor
    public func actualSize() {
        set(1)
    }
}

extension FocusedValues {
    /// The zoom of the screen in the key window that has zoomable content (`.contentZoomable()`).
    @Entry public var contentZoom: ContentZoomControl?
}

extension EnvironmentValues {
    /// The content's scale (1 = 100 %), set by `.contentZoomable()` from the stored value; 1
    /// everywhere else (chrome, other screens, iOS, renders unless they set it).
    @Entry public var contentZoom: CGFloat = 1
}

extension View {
    /// Marks this screen's content as zoomable (apply once, at the screen's root): sets
    /// `\.contentZoom` from the stored value for everything inside and publishes the View menu's
    /// zoom items (and ⌘=) while the screen shows in the key window. Mac only; on iOS it does
    /// nothing.
    public func contentZoomable() -> some View {
        modifier(ContentZoomModifier())
    }
}

struct ContentZoomModifier: ViewModifier {
    #if os(macOS)
    @AppStorage(ContentZoom.defaultsKey) private var stored: Double = 1
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        let scale = ContentZoom.step(stored)
        let control = ContentZoomControl(scale: scale) { stored = $0 }
        content
            .environment(\.contentZoom, CGFloat(scale))
            .focusedSceneValue(\.contentZoom, control)
            .background { EqualsZoomKey(control: control) }
        #else
        content
        #endif
    }
}

#if os(macOS)
/// ⌘= zooms in too (the unshifted key of ⌘+ on US layouts, as in Safari and Word): a key-only
/// button, never drawn and never hit; its key detaches at 200 %.
private struct EqualsZoomKey: View {
    let control: ContentZoomControl

    var body: some View {
        Button {
            control.zoomIn()
        } label: {
            EmptyView()
        }
        .buttonStyle(.plain)
        .keyboardShortcut(control.canZoomIn ? KeyboardShortcut("=", modifiers: .command) : nil)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// View ▸ Actual Size ⌘0, Zoom In ⌘+, Zoom Out ⌘− for the key window's zoomable screen. The keys
/// attach only while such a screen shows (AppKit lets a disabled item swallow its key).
///
///     WindowGroup { … }.commands { ContentZoomCommands() }
public struct ContentZoomCommands: Commands {
    @FocusedValue(\.contentZoom) private var zoom

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Actual Size") { zoom?.actualSize() }
                .keyboardShortcut(zoom != nil ? KeyboardShortcut("0", modifiers: .command) : nil)
                .disabled(zoom == nil || zoom?.isActualSize == true)
            Button("Zoom In") { zoom?.zoomIn() }
                .keyboardShortcut(zoom != nil ? KeyboardShortcut("+", modifiers: .command) : nil)
                .disabled(zoom?.canZoomIn != true)
            Button("Zoom Out") { zoom?.zoomOut() }
                .keyboardShortcut(zoom != nil ? KeyboardShortcut("-", modifiers: .command) : nil)
                .disabled(zoom?.canZoomOut != true)
            Divider()
        }
    }
}
#endif
