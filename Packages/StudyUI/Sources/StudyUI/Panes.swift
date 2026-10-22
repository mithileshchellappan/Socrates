import SwiftUI

// Panes (docs/DESIGN.md 6.4): the vocabulary feature screens use to offer their side panes and to
// react to the window's resizing, without depending on the Panes package (the Mac's AppKit host,
// which only the app imports). A screen offers its panes with `.pane(_:identity:…)`; the app's
// `PaneHost` (Panes) reads the offers, lays the open ones out as columns right of the screen, each
// in its own hosting view, and gives every pane a 36 pt header (title or accessory, Maximize,
// Close). On iOS nothing reads the offers: the iPad keeps its inspectors.
//
// The cross-graph rule: a pane's content is drawn in another hosting view than the screen, so it
// sees the screen's state ONLY through `@Observable` objects its closure captures (a review's
// model, a page's state object). Never through `@State` values, bindings, `@FocusState`, the
// screen's own environment or preferences: those do not cross hosting views and go stale or do
// nothing. The content closure is called again only when the offer's identity changes.

/// A pane's stable name: layouts stored per screen kind name panes by it.
public struct PaneID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Review's notes: This slide | Whole lecture | Summary.
    public static let notes = PaneID("notes")
    /// The lecture notes page's Your notes: the lecture's own note, then the notes by slide.
    public static let yourNotes = PaneID("yourNotes")
    /// Calendar's Deadlines.
    public static let deadlines = PaneID("deadlines")
    /// The agent's conversation (every main-window screen while Claude Code is available).
    public static let agent = PaneID("agent")
}

/// What a pane's content shows: the content is built again only when this changes (another
/// lecture, another loaded review). Any hashable, sendable value.
public struct PaneIdentity: Hashable, Sendable {
    private let base: any Hashable & Sendable

    public init(_ base: some Hashable & Sendable) {
        self.base = base
    }

    public static func == (lhs: PaneIdentity, rhs: PaneIdentity) -> Bool {
        AnyHashable(lhs.base) == AnyHashable(rhs.base)
    }

    public func hash(into hasher: inout Hasher) {
        AnyHashable(base).hash(into: &hasher)
    }
}

/// One pane a screen offers: its content, an optional header accessory (the agent's conversation
/// menu, Review's tab picker) and what puts the caret in it (the agent's composer). Equal when the
/// id, the identity and whether it has an accessory are: a new closure alone never rebuilds the
/// pane.
public struct PaneOffer: Equatable, Sendable {
    public var id: PaneID
    public var identity: PaneIdentity
    public var content: @MainActor @Sendable () -> AnyView
    public var accessory: (@MainActor @Sendable () -> AnyView)?
    public var focus: (@MainActor @Sendable () -> Void)?

    public init(
        id: PaneID,
        identity: PaneIdentity,
        content: @escaping @MainActor @Sendable () -> AnyView,
        accessory: (@MainActor @Sendable () -> AnyView)? = nil,
        focus: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.identity = identity
        self.content = content
        self.accessory = accessory
        self.focus = focus
    }

    public static func == (lhs: PaneOffer, rhs: PaneOffer) -> Bool {
        lhs.id == rhs.id && lhs.identity == rhs.identity && (lhs.accessory == nil) == (rhs.accessory == nil)
    }
}

/// The offers of the view tree under the pane host: siblings in order, an offer after the ones of
/// the view it is applied to (a later offer of the same id wins).
public struct PaneOfferKey: PreferenceKey {
    public static let defaultValue: [PaneOffer] = []

    public static func reduce(value: inout [PaneOffer], nextValue: () -> [PaneOffer]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Offers a pane beside this screen. Its content is called on the main actor in the pane's own
    /// hosting view, again only when `identity` changes; it reads the screen's state through the
    /// `@Observable` objects it captures. Without a pane host (iOS, renders) nothing happens.
    public func pane<Content: View>(
        _ id: PaneID,
        identity: some Hashable & Sendable,
        focus: (@MainActor @Sendable () -> Void)? = nil,
        @ViewBuilder content: @escaping @MainActor @Sendable () -> Content
    ) -> some View {
        // Added to the offers under it (a screen's own), never in their place.
        transformPreference(PaneOfferKey.self) { offers in
            offers.append(PaneOffer(id: id, identity: PaneIdentity(identity), content: { AnyView(content()) }, focus: focus))
        }
    }

    /// Offers a pane with a header accessory (drawn after the title, or in its place where the
    /// pane's spec hides the title).
    public func pane<Content: View, Accessory: View>(
        _ id: PaneID,
        identity: some Hashable & Sendable,
        focus: (@MainActor @Sendable () -> Void)? = nil,
        @ViewBuilder accessory: @escaping @MainActor @Sendable () -> Accessory,
        @ViewBuilder content: @escaping @MainActor @Sendable () -> Content
    ) -> some View {
        transformPreference(PaneOfferKey.self) { offers in
            offers.append(PaneOffer(
                id: id, identity: PaneIdentity(identity), content: { AnyView(content()) },
                accessory: { AnyView(accessory()) }, focus: focus
            ))
        }
    }
}

/// Opens, closes and asks about the window's panes (the agent panel's Expand / Shrink Chat, ⌘J
/// while the Agent pane is open). `isOpen` reads the host's observed state: called in a body, the
/// view follows it.
public struct PaneControl: Sendable {
    /// A pane host is installed (the Mac's main window); false on iOS and in renders.
    public var isInstalled: Bool
    public var isOpen: @MainActor @Sendable (PaneID) -> Bool
    /// Opens the pane under the room rules (the sidebar hides first, the widest pane gives way, at
    /// worst it opens maximized); `focus` puts the caret in it (its offer's `focus`).
    public var open: @MainActor @Sendable (_ id: PaneID, _ focus: Bool) -> Void
    public var close: @MainActor @Sendable (PaneID) -> Void

    public init(
        isInstalled: Bool,
        isOpen: @escaping @MainActor @Sendable (PaneID) -> Bool,
        open: @escaping @MainActor @Sendable (_ id: PaneID, _ focus: Bool) -> Void,
        close: @escaping @MainActor @Sendable (PaneID) -> Void
    ) {
        self.isInstalled = isInstalled
        self.isOpen = isOpen
        self.open = open
        self.close = close
    }

    /// No host: nothing is open, nothing opens.
    public static let none = PaneControl(isInstalled: false, isOpen: { _ in false }, open: { _, _ in }, close: { _ in })
}

/// Where the floating panel (the agent's small chat) sits and how big it is: its offset from the
/// content area's bottom-trailing corner and its size, in points. `height` nil: as tall as its
/// content (up to half the window) until the student resizes it. Stored as "dx,dy,w,h" (`h` empty
/// while it hugs its content).
public struct FloatingPanelFrame: RawRepresentable, Hashable, Sendable {
    public var dx: Double
    public var dy: Double
    public var width: Double
    public var height: Double?

    public init(dx: Double, dy: Double, width: Double, height: Double?) {
        self.dx = dx
        self.dy = dy
        self.width = width
        self.height = height
    }

    /// 12 pt from the trailing and bottom edges, 336 wide, hugging its content.
    public static let initial = FloatingPanelFrame(dx: 12, dy: 12, width: 336, height: nil)
    /// The smallest a resize leaves it.
    public static let minimumSize = CGSize(width: 280, height: 160)
    /// The margin it keeps from the content area's edges.
    public static let margin: Double = 12

    /// It sits in its corner (where the window's toasts stack above it).
    public var sitsInCorner: Bool {
        dx <= Self.margin + 0.5 && dy <= Self.margin + 0.5
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        guard parts.count == 4, let dx = parts[0], let dy = parts[1], let width = parts[2] else { return nil }
        self.init(dx: dx, dy: dy, width: width, height: parts[3])
    }

    public var rawValue: String {
        let height = height.map { String(Int($0.rounded())) } ?? ""
        return "\(Int(dx.rounded())),\(Int(dy.rounded())),\(Int(width.rounded())),\(height)"
    }
}

/// Moves the floating panel from a drag on its title row: the panel's host moves its layer (no
/// layout, no body) and stores the place when the drag ends. The title row keeps its buttons and
/// menu; only the drag's translation crosses over.
public struct FloatingPanelMover: Sendable {
    /// The drag's translation since it began, in window points (right and down positive).
    public var changed: @MainActor @Sendable (CGSize) -> Void
    public var ended: @MainActor @Sendable () -> Void

    public init(changed: @escaping @MainActor @Sendable (CGSize) -> Void, ended: @escaping @MainActor @Sendable () -> Void) {
        self.changed = changed
        self.ended = ended
    }
}

extension EnvironmentValues {
    /// The window's panes (`PaneControl.none` without a host).
    @Entry public var paneControl = PaneControl.none
    /// A divider, the window's edge or the floating panel is being dragged: heavy content keeps
    /// its last layout until it ends (`defersReflowWhileResizing()`; the slide scales its last
    /// bitmap). Flips twice per drag, never per frame.
    @Entry public var isLiveResizing = false
    /// Inside a pane that is maximized over the content area (the agent keeps a 720 pt measure).
    @Entry public var paneIsMaximized = false
    /// The screen is covered by a maximized pane: its plain keys stand down (nothing pages a slide
    /// the student cannot see).
    @Entry public var mainIsCovered = false
    /// Inside the floating panel: the drag on its title row moves it (nil elsewhere).
    @Entry public var floatingPanelMover: FloatingPanelMover?
    /// Inside the floating panel: its place and size as last stored (nil elsewhere).
    @Entry public var floatingPanelFrame: FloatingPanelFrame?
}

extension View {
    /// While `\.isLiveResizing` is on, this view keeps the width it had when the drag began
    /// (leading, clipped) and lays out again once, when the drag ends: tables, code, figures,
    /// thumbnails. Text around it reflows live.
    public func defersReflowWhileResizing() -> some View {
        modifier(DefersReflow())
    }
}

private struct DefersReflow: ViewModifier {
    @Environment(\.isLiveResizing) private var isLiveResizing
    /// The width as last laid out, kept without re-rendering (written on every layout).
    @State private var measured = MeasuredWidth()
    /// The width held while a drag runs.
    @State private var held: CGFloat?

    func body(content: Content) -> some View {
        let measured = measured
        content
            .frame(width: held, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                measured.value = width
            }
            .frame(maxWidth: held == nil ? nil : .infinity, alignment: .leading)
            .clipShape(HeldClip(isHeld: held != nil))
            .onChange(of: isLiveResizing, initial: true) { _, resizing in
                let width = measured.value
                held = resizing && width > 0 ? width : nil
            }
    }
}

@MainActor
private final class MeasuredWidth {
    var value: CGFloat = 0
}

/// Clips only while a width is held (a shape, so the view's identity never changes).
private struct HeldClip: Shape {
    let isHeld: Bool

    func path(in rect: CGRect) -> Path {
        Path(isHeld ? rect : rect.insetBy(dx: -100_000, dy: -100_000))
    }
}
