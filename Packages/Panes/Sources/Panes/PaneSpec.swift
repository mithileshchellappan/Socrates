#if os(macOS)
import StudyUI
import SwiftUI

/// One pane a screen kind offers: its toggle (title, glyph), its widths and how it opens. The app
/// keeps the table (which kind offers which panes, in toolbar order, the agent last), so the toggles
/// and the room a pane needs exist in the same update as the screen; only the content arrives
/// with the screen's offer.
public struct PaneSpec: Hashable, Sendable, Identifiable {
    /// The narrowest and widest any pane gets (DESIGN 3.3).
    public static let minimumWidth: CGFloat = 260
    public static let maximumWidth: CGFloat = 560
    /// A stacked pane keeps its header and this much content.
    public static let minimumStackedContent: CGFloat = 120
    /// The header's height, under the toolbar.
    public static let headerHeight: CGFloat = 36

    public var id: PaneID
    /// The header's title ("Your notes", "Deadlines", "Agent"), localized; not drawn while
    /// `showsTitle` is false.
    public var title: String
    /// The toggle's help and the View menu's name, in title case ("Your Notes", "Notes").
    public var menuTitle: String
    public var systemImage: String
    public var minWidth: CGFloat
    public var idealWidth: CGFloat
    public var maxWidth: CGFloat
    /// Open in a screen kind's first layout.
    public var opensByDefault: Bool
    /// Open or closed for the whole window, not per screen kind (the agent: one conversation across
    /// screens). Its column, width and stack place are still kept per kind.
    public var opensPerWindow: Bool
    /// The header shows the title; false: the offer's accessory takes its place (Review's tab
    /// picker).
    public var showsTitle: Bool

    public init(
        id: PaneID,
        title: String,
        menuTitle: String? = nil,
        systemImage: String,
        minWidth: CGFloat = PaneSpec.minimumWidth,
        idealWidth: CGFloat = 336,
        maxWidth: CGFloat = PaneSpec.maximumWidth,
        opensByDefault: Bool = false,
        opensPerWindow: Bool = false,
        showsTitle: Bool = true
    ) {
        self.id = id
        self.title = title
        self.menuTitle = menuTitle ?? title
        self.systemImage = systemImage
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.opensByDefault = opensByDefault
        self.opensPerWindow = opensPerWindow
        self.showsTitle = showsTitle
    }
}

/// The kind of screen a layout is kept for (`Socrates.panes.<kind>`): every lecture's review
/// opens like the last one left, the lecture notes page keeps its own arrangement.
public struct PaneScreenKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let review = PaneScreenKind(rawValue: "review")
    public static let lectureNotes = PaneScreenKind(rawValue: "lectureNotes")
    public static let calendar = PaneScreenKind(rawValue: "calendar")
    /// Every other main-window screen (it offers the agent only).
    public static let general = PaneScreenKind(rawValue: "general")
}

/// What the window keeps beside the panes, as the app declares it (never measured): the screen's
/// minimum (480; Mail 700) and the sidebar's width while it shows (0 while hidden).
public struct PaneRoom: Equatable, Sendable {
    public var screenMinimum: CGFloat
    public var sidebar: CGFloat

    public init(screenMinimum: CGFloat, sidebar: CGFloat) {
        self.screenMinimum = screenMinimum
        self.sidebar = sidebar
    }
}
#endif
