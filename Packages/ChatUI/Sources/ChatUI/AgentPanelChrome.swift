import StudyUI
import SwiftUI

/// Sizes of the chat (docs/plan-agent.md §6).
enum AgentPanelMetrics {
    /// The small chat's width and its inset from the window's trailing and bottom edges (on the
    /// Mac the floating panel's own; the iPad's overlay and renders draw them here).
    static let compactWidth: CGFloat = 336
    static let margin: CGFloat = 12
    static let radius: CGFloat = 14
    /// The small chat's title row; the iPad's expanded header is level with the toolbar.
    static let compactHeader: CGFloat = 38
    static let expandedHeader: CGFloat = 52
    /// The iPad's expanded column: min, ideal, max.
    static let minWidth: CGFloat = 300
    static let idealWidth: Double = 380
    static let maxWidth: CGFloat = 560
    /// The window toolbar's height (the iPad's compact panel never goes under it).
    static let toolbarHeight: CGFloat = 52
    /// The conversation's title menu at its widest: a long title truncates, so the header keeps
    /// room for its buttons (and the small chat room to be dragged by).
    static let titleWidth: CGFloat = 200
    /// The Agent pane's measure while maximized over the content area.
    static let maximizedMeasure: CGFloat = 720
}

/// The small chat's surface, edge and shadow for the iPad's overlay and for renders (the Mac's
/// floating panel draws its own). The shadow is the surface shape's (the panel is opaque): drawn
/// from a plain shape, not from the panel's contents, so moving the panel only moves it. As the
/// mockup's `--panel-shadow` (0 18 40, spread −14 / −12): cast by an inset copy of the shape, so it
/// falls below the panel and never clouds the rows above or beside it; a 0.5 pt ring at black 12 %
/// (white 14 % in dark).
struct CompactPanelChrome: ViewModifier {
    var isDropTargeted = false
    /// Renders: AppKit's `cacheDisplay` (the off-screen composite) draws a layer's shadow offset
    /// upside down, so the render's panel casts it up to look as the window's does.
    var isCachedDisplay = false

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AgentPanelMetrics.radius, style: .continuous)
        let isDark = colorScheme == .dark
        let shadow = isDark ? Color.black.opacity(0.70) : Color(red: 20 / 255, green: 30 / 255, blue: 50 / 255).opacity(0.38)
        let ring = isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
        let drop: CGFloat = isCachedDisplay ? -18 : 18
        content
            .frame(width: AgentPanelMetrics.compactWidth)
            .clipShape(shape)
            .background {
                ZStack {
                    shape
                        .inset(by: isDark ? 12 : 14)
                        .fill(PanelSurface())
                        .shadow(color: shadow, radius: 20, y: drop)
                    shape.fill(PanelSurface())
                }
            }
            .overlay {
                shape.strokeBorder(ring, lineWidth: 0.5)
            }
            .overlay {
                if isDropTargeted {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
    }
}

/// The inspector's opaque surface (#f8f8fa / #222225, the Live inspector's `Color.inspector
/// Background`, internal to CaptureUI; promote both into StudyUI): answers are content, never
/// glass.
struct PanelSurface: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        environment.colorScheme == .dark
            ? Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x25 / 255).resolve(in: environment)
            : Color(red: 0xF8 / 255, green: 0xF8 / 255, blue: 0xFA / 255).resolve(in: environment)
    }
}

/// The expanded chat's opaque surface, as the small chat's (mockup `.agent { background:
/// var(--inspector) }`, #f8f8fa / #222225), with a 0.5 pt hairline on its leading edge where it
/// stands beside the screen on its own (the iPad's column, renders): nothing of the screen beside
/// it shows through. The Mac's pane host draws the dividers between panes itself.
struct ExpandedPanelBackground: View {
    var showsEdge = true

    var body: some View {
        Rectangle()
            .fill(PanelSurface())
            .overlay(alignment: .leading) {
                if showsEdge { Hairline(.vertical) }
            }
            .ignoresSafeArea()
    }
}

// MARK: - Toast clearance

extension View {
    /// While the small chat sits in its corner, the window's toasts stay above it (and above
    /// whatever a screen reserved before, which comes back when the chat goes).
    func reservesPanelSpace(_ height: CGFloat, isActive: Bool) -> some View {
        modifier(PanelOverlaySpace(height: isActive ? height : 0))
    }
}

private struct PanelOverlaySpace: ViewModifier {
    let height: CGFloat
    @Environment(\.overlayInsets) private var insets
    @State private var before: CGFloat?
    @State private var applied: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onAppear { apply(height) }
            .onChange(of: height) { _, height in apply(height) }
            .onDisappear {
                guard let insets else { return }
                if insets.bottom == applied { insets.bottom = before ?? 0 }
            }
    }

    private func apply(_ height: CGFloat) {
        guard let insets else { return }
        if before == nil || insets.bottom != applied { before = insets.bottom }
        applied = max(before ?? 0, height)
        insets.bottom = applied
    }
}
