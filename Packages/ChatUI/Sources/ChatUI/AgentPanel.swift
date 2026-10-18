import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

// The agent panel (ma, docs/plan-agent.md §6): ONE panel for the whole main window. Compact, it
// floats over the content near the bottom-trailing corner (movable by its title row, the place
// kept per window); expanded, it is the window's full-height trailing inspector column (resizable,
// the width kept). One conversation across screens: the screen only changes what the next message
// is about (the context, read at ↩).

extension View {
    /// Installs the agent panel on the main window's split view (once): the compact panel as an
    /// overlay, the expanded one as the window's trailing inspector column, View ▸ Show Chat ⌘J /
    /// Expand Chat ⌥⌘J (`AgentPanelCommands`), `\.openAgentPanel`, `\.agentPanelExpanded` and the
    /// composer's focus (`\.isAgentComposerFocused`, also folded into `\.isSearchFieldFocused`, so
    /// apply it inside the app's own `.environment(\.isSearchFieldFocused, …)`). Without
    /// `AgentPanelActions.isAvailable` none of it shows.
    ///
    /// - Parameters:
    ///   - context: what the app knows of where the student is (screen, course, mail, note,
    ///     search); a screen's `.agentContext` publication is merged over it.
    ///   - launch: how the panel starts (renders); closed by default.
    ///   - floatingLauncher: draws the launcher's floating form at the window's bottom-left corner
    ///     (while the sidebar, whose footer holds `AgentPanelLauncher`, is collapsed).
    public func agentPanel(context: AgentContext, launch: AgentPanelLaunch = AgentPanelLaunch(), floatingLauncher: Bool = false) -> some View {
        modifier(AgentPanelModifier(context: context, launch: launch, floatingLauncher: floatingLauncher))
    }

    /// Reads what the screen in this column publishes (`.agentContext`) for the window's panel.
    /// `.agentPanel` reads it too, but a split view's columns are hosted apart and their
    /// preferences may stop at the column: apply this to the detail column's root as well.
    public func agentPanelContextReader() -> some View {
        modifier(AgentContextReader())
    }
}

/// Sizes of the panel (docs/plan-agent.md §6).
enum AgentPanelMetrics {
    /// The compact panel's width and its inset from the window's trailing and bottom edges.
    static let compactWidth: CGFloat = 336
    static let margin: CGFloat = 12
    static let radius: CGFloat = 14
    /// The compact title row; the expanded header is level with the toolbar.
    static let compactHeader: CGFloat = 38
    static let expandedHeader: CGFloat = 52
    /// The expanded column: min, ideal, max.
    static let minWidth: CGFloat = 300
    static let idealWidth: Double = 380
    static let maxWidth: CGFloat = 560
    /// The window toolbar's height (the compact panel never goes under it).
    static let toolbarHeight: CGFloat = 52
    /// The toolbar's inset from the window's trailing edge (the expanded header's toolbar item).
    static let toolbarTrailingInset: CGFloat = 11
}

/// What one window's panel shows and holds: its size, the conversation, the composer's text and
/// files, the message sent but not stored yet, and which part of the thread the compact panel
/// shows.
@MainActor
@Observable
final class AgentPanelModel {
    enum Mode: Hashable {
        case closed
        case compact
        case expanded
    }

    /// Which exchanges the compact panel shows.
    enum ThreadWindow: Hashable {
        /// Those sent since it opened (and task results since then), and always at least the
        /// conversation's latest exchange: an answer never hides behind ⤢.
        case since(Date)
        /// A conversation picked in the title menu: its last exchange.
        case last
        /// Renders: these exchanges.
        case exchanges(Range<Int>)
    }

    var mode: Mode
    /// The conversation picked in the title menu, or the one the last message went to.
    var selected: AgentConversation.ID?
    /// New Chat: no conversation until its first message.
    var startsNew: Bool
    var draft: String
    var attachments: [AgentAttachment]
    /// Files being read (drop, paste, paperclip).
    var reading = 0
    var pending: PendingPanelMessage?
    var isSending = false
    /// The conversation on screen is answering (its thread reports it).
    var isRunning = false
    /// Stored turns of the conversation on screen (a pending message follows exactly these).
    var turnCount = 0
    /// The student asked something since the panel opened: the prompt turns to "Ask a follow-up…".
    var askedSinceOpen = false
    /// Mirrors the composer's focus.
    var composerFocused = false
    /// Bumped to put the caret in the composer.
    var focusRequests = 0
    var shown: ThreadWindow
    /// What the screen on display publishes (`.agentContext`).
    var source: AgentContextSource?
    let fixedNow: Date?

    init(launch: AgentPanelLaunch) {
        switch launch.mode {
        case .closed: mode = .closed
        case .compact: mode = .compact
        case .expanded: mode = .expanded
        }
        selected = launch.conversationID
        startsNew = launch.newChat
        draft = launch.draft
        attachments = launch.attachments
        fixedNow = launch.now
        shown = launch.exchanges.map(ThreadWindow.exchanges) ?? .since(Date())
    }

    var now: Date { fixedNow ?? Date() }
    var isOpen: Bool { mode != .closed }

    /// A message may go now: none is being handed over or waiting for its stored turn, the agent
    /// is not answering, no file is still being read.
    var canSendNow: Bool { !isSending && pending == nil && !isRunning && reading == 0 }

    /// The conversation on screen: a new chat's (nil until its first message), else the picked
    /// one, else the newest.
    func conversationID(newest: AgentConversation.ID?) -> AgentConversation.ID? {
        startsNew ? selected : (selected ?? newest)
    }

    /// ⌘J, the launcher, Calendar's [+]: opens compact (or expanded) with the caret in the
    /// composer; a compact panel opened again shows the conversation's latest exchange.
    func open(expanded: Bool = false) {
        if mode == .closed {
            shown = .since(Date())
            askedSinceOpen = false
        }
        mode = expanded ? .expanded : (mode == .expanded ? .expanded : .compact)
        focusRequests += 1
    }

    func close() {
        mode = .closed
        composerFocused = false
    }

    /// ⌘J and the launcher.
    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// ⌥⌘J and ⤢ / ⤡: closed or compact → expanded; expanded → compact.
    func toggleExpanded() {
        switch mode {
        case .closed: open(expanded: true)
        case .compact: mode = .expanded
        case .expanded: mode = .compact
        }
        focusRequests += 1
    }

    func newChat() {
        startsNew = true
        selected = nil
        pending = nil
        askedSinceOpen = false
        shown = .since(Date())
        focusRequests += 1
    }

    /// A conversation from the title menu.
    func pick(_ id: AgentConversation.ID) {
        startsNew = false
        selected = id
        pending = nil
        askedSinceOpen = false
        shown = .last
        focusRequests += 1
    }

    /// The context a message carries: the app's, with the screen's publication (and its
    /// `refine`, the playhead) merged over it.
    func sendContext(app: AgentContext) -> AgentContext {
        source.map { app.merging($0.current()) } ?? app
    }

    /// The context as the panel shows it (prompt, context lines): settled, no playhead.
    func shownContext(app: AgentContext) -> AgentContext {
        (source.map { app.merging($0.context) } ?? app).settled
    }

    // MARK: Files

    var canAttach: Bool { attachments.count + reading < AgentAttachment.maximumPerMessage }
    var hasFiles: Bool { !attachments.isEmpty }

    /// Reads files into attachments off the main actor; anything the accept rule refuses (or past
    /// five per message) is left out without a word.
    func attach(urls: [URL], blobs: BlobStore) {
        let room = AgentAttachment.maximumPerMessage - attachments.count - reading
        let picked = Array(urls.filter { AgentAttachment.kind(forFileName: $0.lastPathComponent) != nil }.prefix(max(0, room)))
        guard !picked.isEmpty else { return }
        reading += picked.count
        Task {
            for url in picked {
                let made = await Self.make(url: url, blobs: blobs)
                reading -= 1
                if let made { add(made) }
            }
        }
    }

    /// Pasted or dropped bytes (a screenshot; TIFF becomes PNG).
    func attach(data: Data, type: UTType, fileName: String, blobs: BlobStore) {
        guard canAttach, AgentAttachment.kind(for: type) != nil || type.conforms(to: .tiff) else { return }
        reading += 1
        Task {
            let made = await Self.make(data: data, type: type, fileName: fileName, blobs: blobs)
            reading -= 1
            if let made { add(made) }
        }
    }

    func remove(_ attachment: AgentAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    private func add(_ attachment: AgentAttachment) {
        guard !attachments.contains(where: { $0.id == attachment.id }), attachments.count < AgentAttachment.maximumPerMessage else { return }
        attachments.append(attachment)
    }

    @concurrent
    nonisolated private static func make(url: URL, blobs: BlobStore) async -> AgentAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try AgentAttachment.make(fileAt: url, blobs: blobs)
        } catch {
            ChatUILog.ui.notice("Attachment refused: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @concurrent
    nonisolated private static func make(data: Data, type: UTType, fileName: String, blobs: BlobStore) async -> AgentAttachment? {
        var data = data
        var type = type
        var fileName = fileName
        if type.conforms(to: .tiff) {
            // A screenshot on the pasteboard is TIFF; Claude reads PNG.
            guard let png = AttachmentImages.png(fromImageData: data) else { return nil }
            data = png
            type = .png
            fileName = (fileName as NSString).deletingPathExtension + ".png"
        }
        do {
            return try AgentAttachment.make(data: data, contentType: type, fileName: fileName, blobs: blobs)
        } catch {
            ChatUILog.ui.notice("Attachment refused: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// The student's message between ↩ and its stored turn.
struct PendingPanelMessage: Equatable {
    var text: String
    var attachments: [AgentAttachment]
    /// The conversation it went to (nil: a new one, until `send` returns).
    var conversationID: AgentConversation.ID?
    /// Stored turns of that conversation when it was sent.
    var afterTurns: Int
}

extension EnvironmentValues {
    /// The window's panel, for its launcher (nil: no panel installed, or no Claude Code).
    @Entry var agentPanelModel: AgentPanelModel?
}

/// View ▸ Show Chat / Expand Chat of the key window's panel (`AgentPanelCommands`).
@MainActor
struct AgentPanelFocus {
    var isOpen: Bool
    var isExpanded: Bool
    var toggle: @MainActor () -> Void
    var toggleExpanded: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var agentPanel: AgentPanelFocus?
}

struct AgentPanelModifier: ViewModifier {
    let context: AgentContext
    let floatingLauncher: Bool

    @Environment(\.agentPanelActions) private var actions
    @Environment(\.isSearchFieldFocused) private var isSearchFieldFocused
    @State private var model: AgentPanelModel
    @State private var windowSize: CGSize = .zero
    /// The compact panel's place: its offset from the bottom-trailing corner, "x,y".
    @SceneStorage("agent.panel.position") private var position = ""
    @AppStorage("agent.panel.width") private var width = AgentPanelMetrics.idealWidth

    init(context: AgentContext, launch: AgentPanelLaunch, floatingLauncher: Bool) {
        self.context = context
        self.floatingLauncher = floatingLauncher
        _model = State(initialValue: AgentPanelModel(launch: launch))
    }

    func body(content: Content) -> some View {
        let available = actions.isAvailable
        let model = model
        let composing = available && model.composerFocused
        let appContext = context
        let shown = model.shownContext(app: appContext)
        let sendContext: @MainActor () -> AgentContext = { model.sendContext(app: appContext) }
        content
            .environment(\.isSearchFieldFocused, isSearchFieldFocused || composing)
            .environment(\.isAgentComposerFocused, composing)
            .environment(\.agentPanelExpanded, available && model.mode == .expanded)
            .environment(\.openAgentPanel, OpenAgentPanelAction { expanded in
                if available { model.open(expanded: expanded) }
            })
            .environment(\.agentPanelModel, available ? model : nil)
            .onPreferenceChange(AgentContextPreferenceKey.self) { value in
                Task { @MainActor in model.source = value }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
            .overlay(alignment: .bottomLeading) {
                if available, floatingLauncher {
                    AgentPanelLauncher(style: .floating)
                        .padding(AgentPanelMetrics.margin)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if available, model.mode == .compact {
                    CompactAgentPanel(model: model, context: shown, sendContext: sendContext, position: $position, windowSize: windowSize)
                }
            }
            .inspector(isPresented: Binding(
                get: { available && model.mode == .expanded },
                set: { isShown in if !isShown, model.mode == .expanded { model.close() } }
            )) {
                Group {
                    // SwiftUI keeps a hidden inspector's content alive: only while expanded, so its
                    // composer never takes the caret from the compact one.
                    if model.mode == .expanded {
                        ExpandedAgentPanel(model: model, context: shown, sendContext: sendContext, width: $width)
                    } else {
                        Color.clear
                    }
                }
                .inspectorColumnWidth(min: AgentPanelMetrics.minWidth, ideal: width, max: AgentPanelMetrics.maxWidth)
            }
            .focusedSceneValue(\.agentPanel, available ? AgentPanelFocus(
                isOpen: model.isOpen, isExpanded: model.mode == .expanded,
                toggle: { model.toggle() }, toggleExpanded: { model.toggleExpanded() }
            ) : nil)
    }
}

/// `agentPanelContextReader()`: the column's publication into the window's panel.
private struct AgentContextReader: ViewModifier {
    @Environment(\.agentPanelModel) private var model

    func body(content: Content) -> some View {
        content.onPreferenceChange(AgentContextPreferenceKey.self) { value in
            Task { @MainActor in model?.source = value }
        }
    }
}

// MARK: - Compact

/// The floating panel: the inspector's opaque surface, radius 14, a soft panel shadow, 336 wide,
/// as tall as its content up to half the window; moved by dragging its title row, kept inside
/// the window.
///
/// A drag moves it by an offset alone: the title row writes the translation into `PanelMove`,
/// which only `PanelPlacement` reads, so the thread, the composer and their queries are not
/// evaluated or laid out again while it moves; the place is stored once, when the drag ends.
struct CompactAgentPanel: View {
    let model: AgentPanelModel
    let context: AgentContext
    let sendContext: @MainActor () -> AgentContext
    @Binding var position: String
    let windowSize: CGSize

    @State private var move = PanelMove()
    @State private var size = CGSize(width: AgentPanelMetrics.compactWidth, height: 90)
    @State private var isDropTargeted = false

    var body: some View {
        let bounds = PanelBounds(windowSize: windowSize, panelSize: size)
        let stored = bounds.clamp(Self.parse(position))
        let move = move
        AgentPanelView(
            style: .compact, model: model, context: context, sendContext: sendContext,
            maxThreadHeight: Self.maxThreadHeight(windowHeight: windowSize.height),
            move: move,
            moveEnded: { translation in
                position = Self.format(bounds.clamp(stored, adding: translation))
                move.translation = .zero
            }
        )
        .modifier(CompactPanelChrome(isDropTargeted: isDropTargeted))
        .agentFileDrop(model: model, isTargeted: $isDropTargeted)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        // The stored place, not the drag: the toasts' room changes once, when the drag ends.
        .reservesPanelSpace(size.height + AgentPanelMetrics.margin + 8, isActive: stored.height < 1)
        .modifier(PanelPlacement(move: move, stored: stored, bounds: bounds))
        .padding(.trailing, AgentPanelMetrics.margin)
        .padding(.bottom, AgentPanelMetrics.margin)
        .transition(.opacity)
    }

    /// The thread's room: the panel is at most half the window (title row and composer included).
    static func maxThreadHeight(windowHeight: CGFloat) -> CGFloat {
        max(80, (windowHeight > 0 ? windowHeight : 740) / 2 - 110)
    }

    static func parse(_ text: String) -> CGSize {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return .zero }
        return CGSize(width: parts[0], height: parts[1])
    }

    static func format(_ offset: CGSize) -> String {
        "\(Int(offset.width.rounded())),\(Int(offset.height.rounded()))"
    }
}

/// The compact panel's drag in flight (window points; right and down positive): written by the
/// title row's gesture, read only by `PanelPlacement`.
@MainActor
@Observable
final class PanelMove {
    var translation: CGSize = .zero
}

/// Where the compact panel may go: its offset from the window's bottom-trailing corner, inside
/// the window under the toolbar, on whole points (the drag and the stored place agree, so the
/// panel does not shift when the drag ends).
struct PanelBounds: Equatable {
    var maxX: CGFloat
    var maxY: CGFloat

    init(windowSize: CGSize, panelSize: CGSize) {
        maxX = max(0, (windowSize.width - panelSize.width - 2 * AgentPanelMetrics.margin).rounded(.down))
        maxY = max(0, (windowSize.height - panelSize.height - 2 * AgentPanelMetrics.margin - AgentPanelMetrics.toolbarHeight).rounded(.down))
    }

    /// An offset plus a drag (a drag right or down moves toward the corner), kept inside.
    func clamp(_ offset: CGSize, adding translation: CGSize = .zero) -> CGSize {
        CGSize(
            width: min(max(0, (offset.width - translation.width).rounded()), maxX),
            height: min(max(0, (offset.height - translation.height).rounded()), maxY)
        )
    }
}

/// Places the compact panel: its stored offset plus the drag in flight. Only this modifier reads
/// the drag, so a drag re-evaluates nothing inside the panel.
private struct PanelPlacement: ViewModifier {
    let move: PanelMove
    let stored: CGSize
    let bounds: PanelBounds

    func body(content: Content) -> some View {
        let offset = bounds.clamp(stored, adding: move.translation)
        content.offset(x: -offset.width, y: -offset.height)
    }
}

/// The compact panel's surface, edge and shadow (the window's panel and its render). The shadow
/// is the surface shape's (the panel is opaque): drawn from a plain shape, not from the panel's
/// contents, so moving the panel only moves it.
struct CompactPanelChrome: ViewModifier {
    var isDropTargeted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AgentPanelMetrics.radius, style: .continuous)
        content
            .frame(width: AgentPanelMetrics.compactWidth)
            .clipShape(shape)
            .background {
                shape
                    .fill(PanelSurface())
                    .shadow(color: .black.opacity(0.22), radius: 20, y: 12)
            }
            .overlay {
                shape.strokeBorder(.separator, lineWidth: 0.5)
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

// MARK: - Expanded

/// The full-height trailing column: the panel at the inspector's place, its title row level with
/// the toolbar (52 pt, a toolbar item while shown), resizable by its leading edge (300–560, the
/// width kept).
struct ExpandedAgentPanel: View {
    let model: AgentPanelModel
    let context: AgentContext
    let sendContext: @MainActor () -> AgentContext
    @Binding var width: Double

    @State private var isDropTargeted = false

    var body: some View {
        AgentPanelView(
            style: .expanded, model: model, context: context, sendContext: sendContext, maxThreadHeight: .infinity,
            headerPlacement: .toolbar
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ExpandedPanelBackground() }
        .overlay {
            if isDropTargeted {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).ignoresSafeArea()
            }
        }
        .agentFileDrop(model: model, isTargeted: $isDropTargeted)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            // The column's width as the student left it (dragging its leading edge).
            let rounded = Double(newWidth.rounded())
            if rounded >= Double(AgentPanelMetrics.minWidth), abs(rounded - width) >= 1 { width = rounded }
        }
    }
}

/// As Review's and Calendar's inspectors: the system's column, lifted by white 2.5 % in dark mode.
struct ExpandedPanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            Rectangle().fill(.white.opacity(0.025)).ignoresSafeArea()
        }
    }
}

// MARK: - Toast clearance

extension View {
    /// While the compact panel sits in its corner, the window's toasts stay above it (and above
    /// whatever a screen reserved before, which comes back when the panel goes).
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

// MARK: - Renders

/// The panel alone, as the window would show it, for off-screen renders (`tools/parity`): the
/// compact panel at its width with its surface and edge, or the expanded column with its header
/// drawn inline (an off-screen host has no toolbar). Reads the rows like the real panel; needs
/// `\.agentPanelActions` with `isAvailable` only for the composer's Send and Stop.
public struct AgentPanelSnapshot: View {
    public enum Style: Hashable, Sendable {
        case compact
        case expanded
    }

    private let style: Style
    private let context: AgentContext
    private let windowHeight: CGFloat
    @State private var model: AgentPanelModel

    /// - Parameters:
    ///   - context: the screen the panel is on (its prompt and context lines).
    ///   - launch: the conversation, the exchanges shown (compact), the composer's text and files.
    ///   - windowHeight: the window it would be in (the compact panel is at most half of it).
    public init(style: Style, context: AgentContext, launch: AgentPanelLaunch, windowHeight: CGFloat = 740) {
        self.style = style
        self.context = context
        self.windowHeight = windowHeight
        _model = State(initialValue: AgentPanelModel(launch: launch))
    }

    public var body: some View {
        let model = model
        let context = context
        switch style {
        case .compact:
            AgentPanelView(
                style: .compact, model: model, context: context.settled, sendContext: { context },
                maxThreadHeight: CompactAgentPanel.maxThreadHeight(windowHeight: windowHeight)
            )
            .modifier(CompactPanelChrome())
        case .expanded:
            AgentPanelView(
                style: .expanded, model: model, context: context.settled, sendContext: { context }, maxThreadHeight: .infinity,
                headerPlacement: .inline
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.background.secondary)
            .overlay(alignment: .leading) { Hairline(.vertical) }
        }
    }
}
