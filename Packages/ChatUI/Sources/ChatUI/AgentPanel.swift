#if os(macOS)
import AppKit
#endif
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
    ///   - room: what the window keeps beside the expanded panel: the screen's minimum and the
    ///     sidebar while it shows (nil: no limit, iOS). The panel opens no wider than the rest. Its
    ///     column shows only while the window has its 300 pt beside them (the app hides its
    ///     sidebar for it, `expandedChanged`); where it never can, even without the sidebar, the
    ///     panel stays compact. Showing the sidebar in a window too narrow for the sidebar, the
    ///     screen and the column turns the panel compact (the student's latest action wins).
    ///   - expandedChanged: the panel became, or stopped being, the window's right sidebar (the
    ///     app hides its sidebar while the window cannot hold both, and brings it back after).
    public func agentPanel(
        context: AgentContext,
        launch: AgentPanelLaunch = AgentPanelLaunch(),
        floatingLauncher: Bool = false,
        room: AgentPanelRoom? = nil,
        expandedChanged: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(AgentPanelModifier(
            context: context, launch: launch, floatingLauncher: floatingLauncher,
            room: room, expandedChanged: expandedChanged
        ))
    }

    /// Reads what the screen in this column publishes (`.agentContext`) for the window's panel.
    /// `.agentPanel` reads it too, but a split view's columns are hosted apart and their
    /// preferences may stop at the column: apply this to the detail column's root as well.
    public func agentPanelContextReader() -> some View {
        modifier(AgentContextReader())
    }
}

/// The expanded panel's column, for the app's window layout.
///
/// The column is the split view's `.inspector` (full height, its header in the toolbar), and the
/// window's minimum is the other columns' minimums plus the column's current width (the app
/// declares the split view's minimum itself: on macOS 26 the split view runs under the column, and
/// measured from its content the column's width counted twice). So the column opens, and may be
/// dragged, no wider than the window has beside the screen's minimum and the sidebar, and it shows
/// only while the window holds its 300 there.
public enum AgentPanelLayout {
    /// The right sidebar's narrowest width: the app keeps room for it beside the sidebar and the
    /// screen, or hides its sidebar for it.
    public static let minWidth: CGFloat = AgentPanelMetrics.minWidth

    /// A window `windowWidth` wide holds the column beside `reserved` (the screen's minimum, and
    /// the sidebar while it shows).
    public static func fits(windowWidth: CGFloat, beside reserved: CGFloat) -> Bool {
        windowWidth - reserved >= minWidth
    }

    /// The widest the column may be beside `reserved`: the rest of the window, 300–560.
    static func widest(windowWidth: CGFloat, beside reserved: CGFloat) -> CGFloat {
        let rest = (windowWidth - reserved).rounded(.down)
        return min(max(rest, minWidth), AgentPanelMetrics.maxWidth)
    }

    /// The window holds the column beside the screen's minimum (and the sidebar). Always without a
    /// `room` (iOS) and before the window is measured.
    static func hasRoom(window: CGFloat, room: AgentPanelRoom?, withSidebar: Bool) -> Bool {
        guard let room, window > 0 else { return true }
        let reserved = withSidebar ? room.screen + room.sidebar : room.screen
        return fits(windowWidth: window, beside: reserved)
    }
}

/// What the window keeps beside the expanded panel: the app's other columns at their narrowest.
public struct AgentPanelRoom: Equatable, Sendable {
    /// The screen's declared minimum width.
    public var screen: CGFloat
    /// The sidebar's width while it shows; 0 while it is hidden.
    public var sidebar: CGFloat

    public init(screen: CGFloat, sidebar: CGFloat) {
        self.screen = screen
        self.sidebar = sidebar
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
    /// The expanded header's title menu in the toolbar: a long title truncates, so the column's
    /// toolbar section holds the title, ⤡ and Close even at the column's narrowest.
    static let toolbarTitleWidth: CGFloat = 200
}

/// What one window's panel shows and holds: its size, the conversation, the composer's text and
/// files, the message sent but not stored yet. Every size shows the whole conversation;
/// only a render may show some of its exchanges.
@MainActor
@Observable
final class AgentPanelModel {
    enum Mode: Hashable {
        case closed
        case compact
        case expanded
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
    /// A message (or Try again) handed over whose run the thread has not seen starting yet: its
    /// skeleton stays and the last run's state line waits (no blink, no stale "Not answered").
    var awaitingRun: AwaitedRun?
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
    /// Why the last message or file did not go ("Claude Code is signed out.", "Lecture3.pdf can't
    /// be read."): one secondary line under the composer until the next edit.
    var notice: String?
    /// Renders only (`AgentPanelLaunch.exchanges`): the exchanges shown. Nil: the whole
    /// conversation.
    let shown: Range<Int>?
    /// The answers being written, one box per conversation, kept across the thread's views (⌥⌘J,
    /// reopening, picking): the text so far shows in their first frame, and a stopped run's text
    /// stays.
    @ObservationIgnored private var liveBoxes: [AgentConversation.ID: LiveReplyBox] = [:]
    /// Bumped by New Chat and a pick: a hand-over that ends after one leaves the student's choice.
    @ObservationIgnored var choices = 0
    /// What the screen on display publishes (`.agentContext`).
    var source: AgentContextSource?
    /// The expanded column has its room in the window: decided when the panel expands, then while
    /// the app makes room (it hides its sidebar); until then the column is not shown.
    var columnFits = true
    /// The window has been measured once (a panel launched expanded waits for it).
    var measured = false
    /// The widest the expanded column may be in this window (`AgentPanelLayout.widest`); read only
    /// by the column's sizer, so a window resize re-renders nothing else.
    var columnMax = AgentPanelMetrics.maxWidth
    /// The window's width, for the width the expanded panel opens at. Not observed: written on
    /// every frame of a window resize, it re-renders nothing.
    @ObservationIgnored var windowWidth: CGFloat = 0
    /// What the app keeps beside the expanded column, as of the last update (not observed).
    @ObservationIgnored var room: AgentPanelRoom?
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
        shown = launch.exchanges
        if let text = launch.pendingText {
            // Renders: a message just sent (its stored turn never comes).
            pending = PendingPanelMessage(text: text, attachments: [], conversationID: launch.conversationID, afterTurns: .max)
            askedSinceOpen = true
        }
    }

    var now: Date { fixedNow ?? Date() }

    /// The answer being written in `id` (one box per conversation, for this window's panel).
    func liveBox(for id: AgentConversation.ID) -> LiveReplyBox {
        if let box = liveBoxes[id] { return box }
        let box = LiveReplyBox()
        liveBoxes[id] = box
        return box
    }
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
    /// composer, on the whole conversation (its latest question in sight).
    func open(expanded: Bool = false) {
        if mode == .closed {
            askedSinceOpen = false
        }
        let wasExpanded = mode == .expanded
        mode = expanded || wasExpanded ? .expanded : .compact
        if mode == .expanded, !wasExpanded { measureColumn() }
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
        case .closed:
            open(expanded: true)
        case .compact:
            mode = .expanded
            measureColumn()
        case .expanded:
            mode = .compact
        }
        focusRequests += 1
    }

    /// In the same update as the panel expands (or another screen with another minimum shows):
    /// the column shows now, or once the app has made room (`columnFits`), so the window never
    /// holds more than it can for a frame.
    func measureColumn() {
        columnFits = AgentPanelLayout.hasRoom(window: windowWidth, room: room, withSidebar: true)
    }

    /// After the window's width or the app's columns changed: the column's widest for them. The
    /// expanded panel turns compact in a window too narrow for the screen's minimum and the column
    /// even without the sidebar (a tile, leaving full screen), and when its shown column no longer
    /// fits beside the sidebar (the student showed or widened it there: their latest action wins).
    /// While the app is still making room (`columnFits` false) the sidebar may show.
    func fitColumn() {
        guard let room, windowWidth > 0 else { return }
        let reserved = room.screen + room.sidebar
        let widest = AgentPanelLayout.widest(windowWidth: windowWidth, beside: reserved)
        if widest != columnMax { columnMax = widest }
        guard mode == .expanded else { return }
        let fitsAlone = AgentPanelLayout.fits(windowWidth: windowWidth, beside: room.screen)
        let fitsBeside = AgentPanelLayout.fits(windowWidth: windowWidth, beside: reserved)
        let shown = measured && columnFits
        if !fitsAlone || (shown && !fitsBeside) { mode = .compact }
    }

    func newChat() {
        startsNew = true
        selected = nil
        pending = nil
        askedSinceOpen = false
        choices += 1
        focusRequests += 1
    }

    /// A conversation from the title menu: the whole conversation, its latest question in sight.
    func pick(_ id: AgentConversation.ID) {
        choices += 1
        startsNew = false
        selected = id
        pending = nil
        askedSinceOpen = false
        notice = nil
        focusRequests += 1
    }

    /// The context a message carries: the app's, with the screen's publication (and its
    /// `refine`, the playhead) merged over it, only while it is about the screen the app is on (a
    /// stale or foreign publication never names another screen: "Ask about your mail" on Mail).
    func sendContext(app: AgentContext) -> AgentContext {
        guard let source, source.context.screen == app.screen else { return app }
        return app.merging(source.current())
    }

    /// The context as the panel shows it (prompt, context lines): settled, no playhead.
    func shownContext(app: AgentContext) -> AgentContext {
        guard let source, source.context.screen == app.screen else { return app.settled }
        return app.merging(source.context).settled
    }

    // MARK: Files

    var canAttach: Bool { attachments.count + reading < AgentAttachment.maximumPerMessage }
    var hasFiles: Bool { !attachments.isEmpty }

    /// Reads files into attachments off the main actor; a file the accept rule refuses (or past
    /// five per message) is left out, and the notice line says so.
    func attach(urls: [URL], blobs: BlobStore) {
        notice = nil
        let room = AgentAttachment.maximumPerMessage - attachments.count - reading
        let accepted = urls.filter { AgentAttachment.kind(forFileName: $0.lastPathComponent) != nil }
        if let refused = urls.first(where: { AgentAttachment.kind(forFileName: $0.lastPathComponent) == nil }) {
            notice = Self.refusal(AgentAttachment.Refusal.unsupportedType, fileName: refused.lastPathComponent)
        } else if accepted.count > max(0, room) {
            notice = String(localized: "At most \(AgentAttachment.maximumPerMessage) files go with one message.")
        }
        let picked = Array(accepted.prefix(max(0, room)))
        guard !picked.isEmpty else { return }
        reading += picked.count
        Task {
            for url in picked {
                let made = await Self.make(url: url, blobs: blobs)
                reading -= 1
                switch made {
                case .success(let attachment): add(attachment)
                case .failure(let error): notice = Self.refusal(error, fileName: url.lastPathComponent)
                }
            }
        }
    }

    /// Pasted or dropped bytes (a screenshot; TIFF becomes PNG).
    func attach(data: Data, type: UTType, fileName: String, blobs: BlobStore) {
        guard canAttach, AgentAttachment.kind(for: type) != nil || type.conforms(to: .tiff) else { return }
        notice = nil
        reading += 1
        Task {
            let made = await Self.make(data: data, type: type, fileName: fileName, blobs: blobs)
            reading -= 1
            switch made {
            case .success(let attachment): add(attachment)
            case .failure(let error): notice = Self.refusal(error, fileName: fileName)
            }
        }
    }

    func remove(_ attachment: AgentAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        notice = nil
    }

    /// The notice for a file that was not attached: "Lecture3.pdf can't be read."
    static func refusal(_ error: any Error, fileName: String) -> String {
        guard let refusal = error as? AgentAttachment.Refusal else {
            return String(localized: "\(fileName) can’t be read.")
        }
        switch refusal {
        case .tooLarge: return String(localized: "\(fileName) is too large.")
        case .unreadableText, .unreadablePDF: return String(localized: "\(fileName) can’t be read.")
        default: return String(localized: "\(fileName) can’t be attached.")
        }
    }

    private func add(_ attachment: AgentAttachment) {
        guard !attachments.contains(where: { $0.id == attachment.id }), attachments.count < AgentAttachment.maximumPerMessage else { return }
        attachments.append(attachment)
    }

    @concurrent
    nonisolated private static func make(url: URL, blobs: BlobStore) async -> Result<AgentAttachment, any Error> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return .success(try AgentAttachment.make(fileAt: url, blobs: blobs))
        } catch {
            ChatUILog.ui.notice("Attachment refused: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }
    }

    @concurrent
    nonisolated private static func make(data: Data, type: UTType, fileName: String, blobs: BlobStore) async -> Result<AgentAttachment, any Error> {
        var data = data
        var type = type
        var fileName = fileName
        if type.conforms(to: .tiff) {
            // A screenshot on the pasteboard is TIFF; Claude reads PNG.
            guard let png = AttachmentImages.png(fromImageData: data) else { return .failure(AgentAttachment.Refusal.unsupportedType) }
            data = png
            type = .png
            fileName = (fileName as NSString).deletingPathExtension + ".png"
        }
        do {
            return .success(try AgentAttachment.make(data: data, contentType: type, fileName: fileName, blobs: blobs))
        } catch {
            ChatUILog.ui.notice("Attachment refused: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }
    }
}

/// The student's message between ↩ and its stored turn.
struct PendingPanelMessage: Equatable {
    /// This hand-over (its bubble, its context line, the scroll to the end on ↩).
    var id = UUID()
    var text: String
    var attachments: [AgentAttachment]
    /// The conversation it went to (nil: a new one, until `send` returns).
    var conversationID: AgentConversation.ID?
    /// Stored turns of that conversation when it was sent.
    var afterTurns: Int
    /// When ↩ sent it (M7, the sheet: its request row, written after this, takes over).
    var sentAt = Date()
    /// The context it went with, settled (nil: renders).
    var context: AgentContext?
    /// Its faint context line (the screen's glyph and label), once known; drawn only when the
    /// screen changed since the last exchange, as the stored turn will draw it.
    var line: AgentContextLine?
}

/// A run asked for (↩, Try again) and not seen starting yet.
struct AwaitedRun: Equatable {
    /// Nil: a new conversation, until `send` returns its id.
    var conversationID: AgentConversation.ID?
    var sentAt: Date
    /// Try again: the unsaved text of the answer it replaces (hidden meanwhile, dropped once the
    /// run starts, back when it could not go).
    var replaces: [ChatLiveReply] = []
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
    let room: AgentPanelRoom?
    let expandedChanged: ((Bool) -> Void)?

    @Environment(\.agentPanelActions) private var actions
    @Environment(\.isSearchFieldFocused) private var isSearchFieldFocused
    @State private var model: AgentPanelModel
    /// The compact panel's place: its offset from the bottom-trailing corner, "x,y".
    @SceneStorage("agent.panel.position") private var position = ""
    /// The expanded column's width as the student last dragged it.
    @AppStorage("agent.panel.width") private var width = AgentPanelMetrics.idealWidth

    init(context: AgentContext, launch: AgentPanelLaunch, floatingLauncher: Bool, room: AgentPanelRoom?, expandedChanged: ((Bool) -> Void)?) {
        self.context = context
        self.floatingLauncher = floatingLauncher
        self.room = room
        self.expandedChanged = expandedChanged
        _model = State(initialValue: AgentPanelModel(launch: launch))
    }

    func body(content: Content) -> some View {
        let available = actions.isAvailable
        let model = model
        let composing = available && model.composerFocused
        let expanded = available && model.mode == .expanded
        let appContext = context
        let shown = model.shownContext(app: appContext)
        let sendContext: @MainActor () -> AgentContext = { model.sendContext(app: appContext) }
        // The column shows once the window holds it beside the screen and the sidebar (the app
        // hides its sidebar for it first), and gives way in the very update the sidebar shows or
        // widens where they do not fit (`fitColumn` then turns the panel compact): never all
        // three in a window too narrow for them, not even for a frame.
        let fitsNow = AgentPanelLayout.hasRoom(window: model.windowWidth, room: room, withSidebar: true)
        let measured = room == nil || model.measured
        let presented = expanded && measured && model.columnFits && fitsNow
        let stored: CGFloat = min(max(CGFloat(width), AgentPanelMetrics.minWidth), AgentPanelMetrics.maxWidth)
        let widest: CGFloat = widestNow()
        content
            .environment(\.isSearchFieldFocused, isSearchFieldFocused || composing)
            .environment(\.isAgentComposerFocused, composing)
            .environment(\.agentPanelExpanded, expanded)
            .environment(\.openAgentPanel, OpenAgentPanelAction { expanded in
                if available { model.open(expanded: expanded) }
            })
            .environment(\.agentPanelModel, available ? model : nil)
            .onPreferenceChange(AgentContextPreferenceKey.self) { value in
                Task { @MainActor in model.source = value }
            }
            .overlay(alignment: .bottomLeading) {
                if available, floatingLauncher {
                    AgentPanelLauncher(style: .floating)
                        .padding(AgentPanelMetrics.margin)
                }
            }
            .overlay {
                if available, model.mode == .compact {
                    CompactPanelHost(model: model, context: shown, sendContext: sendContext, position: $position)
                        .transition(.opacity)
                }
            }
            .inspector(isPresented: Binding(
                get: { presented },
                set: { isShown in if !isShown, model.mode == .expanded { model.close() } }
            )) {
                // The student's width is the ideal, never a minimum: the column opens no wider than
                // the window has room for beside the sidebar and the screen's minimum, and never
                // gets wider than that (its sizer follows the window).
                PanelColumnSizer(model: model, stored: stored, limit: widest) {
                    // SwiftUI keeps a hidden inspector's content alive: only while shown, so its
                    // composer never takes the caret from the compact one.
                    if presented {
                        ExpandedAgentPanel(model: model, context: shown, sendContext: sendContext, width: $width)
                    } else {
                        Color.clear
                    }
                }
            }
            // The whole window's width (after the inspector: its column included), into the
            // model's unobserved width: a window resize re-renders nothing here (only the column's
            // sizer, while its widest changes).
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                model.windowWidth = width
                // The first measurement may come before the first `room` change is seen.
                model.room = room
                if !model.measured {
                    // The first measurement: a panel launched expanded learns only now whether the
                    // window holds its column, and shows it at once.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if model.mode == .expanded {
                            model.columnFits = AgentPanelLayout.hasRoom(window: width, room: room, withSidebar: true)
                        }
                        model.measured = true
                    }
                }
                model.fitColumn()
            }
            .onChange(of: room, initial: true) { old, new in
                model.room = new
                if model.mode == .expanded, old?.screen != new?.screen {
                    // Another screen with another minimum (Mail's list and reader): as when the
                    // panel expands, the column waits while the app makes room (its sidebar
                    // hides); a screen change is not the student's choice of the sidebar.
                    model.measureColumn()
                }
                if model.mode == .expanded, !model.columnFits,
                   AgentPanelLayout.hasRoom(window: model.windowWidth, room: new, withSidebar: true) {
                    // The app made room (its sidebar hid, at once): the column shows, at once too.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { model.columnFits = true }
                }
                model.fitColumn()
            }
            .onChange(of: expanded, initial: true) { _, isExpanded in
                expandedChanged?(isExpanded)
                // A window too narrow for the screen's minimum and the column even without the
                // sidebar keeps the panel compact.
                if isExpanded { model.fitColumn() }
            }
            .focusedSceneValue(\.agentPanel, available ? AgentPanelFocus(
                isOpen: model.isOpen, isExpanded: model.mode == .expanded,
                toggle: { model.toggle() }, toggleExpanded: { model.toggleExpanded() }
            ) : nil)
    }

    /// The widest the expanded column may be beside `room` in the window as last measured, in the
    /// same update as the sidebar shows or hides (the window's minimum never holds the old width
    /// beside the new sidebar for a frame).
    private func widestNow() -> CGFloat {
        guard let room, model.windowWidth > 0 else { return AgentPanelMetrics.maxWidth }
        return AgentPanelLayout.widest(windowWidth: model.windowWidth, beside: room.screen + room.sidebar)
    }
}

/// The expanded column's width: 300 to the window's widest (`limit`, and
/// `AgentPanelModel.columnMax` while the window is resized), opening at the student's width.
/// Its own view, so a change of the widest during a window resize re-renders only this.
private struct PanelColumnSizer<Content: View>: View {
    let model: AgentPanelModel
    /// The student's width (`agent.panel.width`, 300–560).
    let stored: CGFloat
    let limit: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let widest: CGFloat = min(limit, model.columnMax)
        let ideal: CGFloat = min(stored, widest)
        content
            .inspectorColumnWidth(min: AgentPanelMetrics.minWidth, ideal: ideal, max: widest)
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

/// The compact panel's layer over the window: it measures the window itself, so a window resize
/// re-renders the panel's placement only (not the modifier around the whole split view).
struct CompactPanelHost: View {
    let model: AgentPanelModel
    let context: AgentContext
    let sendContext: @MainActor () -> AgentContext
    @Binding var position: String

    @State private var windowSize: CGSize = .zero

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
            .overlay(alignment: .bottomTrailing) {
                CompactAgentPanel(model: model, context: context, sendContext: sendContext, position: $position, windowSize: windowSize)
            }
    }
}

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
    /// The height the window's toasts keep clear of.
    @State private var reserved: CGFloat = 90
    @State private var isDropTargeted = false

    var body: some View {
        let bounds = PanelBounds(windowSize: windowSize, panelSize: size)
        let stored = bounds.clamp(Self.parse(position))
        let move = move
        AgentPanelView(
            style: .compact, model: model, context: context, sendContext: sendContext,
            maxHeight: Self.maxHeight(windowHeight: windowSize.height),
            move: move,
            moveEnded: { translation in
                position = Self.format(bounds.clamp(stored, adding: translation))
                move.translation = .zero
            }
        )
        .modifier(CompactPanelChrome(isDropTargeted: isDropTargeted))
        .agentFileDrop(model: model, isTargeted: $isDropTargeted)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            size = newSize
            // The toasts' room follows a streaming answer in steps of a line or more, and
            // exactly once it ends.
            if abs(newSize.height - reserved) >= 17 || !model.isRunning { reserved = newSize.height }
        }
        .onChange(of: model.isRunning) { _, running in
            if !running { reserved = size.height }
        }
        // The stored place, not the drag: the toasts' room changes once, when the drag ends.
        .reservesPanelSpace(reserved + AgentPanelMetrics.margin + 8, isActive: stored.height < 1)
        .modifier(PanelPlacement(move: move, stored: stored, bounds: bounds))
        .padding(.trailing, AgentPanelMetrics.margin)
        .padding(.bottom, AgentPanelMetrics.margin)
        .transition(.opacity)
    }

    /// The panel is at most half the window (title row, task line and composer included).
    static func maxHeight(windowHeight: CGFloat) -> CGFloat {
        (windowHeight > 0 ? windowHeight : 740) / 2
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
/// contents, so moving the panel only moves it. As the mockup's `--panel-shadow` (0 18 40, spread
/// −14 / −12): cast by an inset copy of the shape, so it falls below the panel and never clouds
/// the rows above or beside it; a 0.5 pt ring at black 12 % (white 14 % in dark).
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

// MARK: - Expanded

/// The full-height trailing column: the panel at the inspector's place, its title row level with
/// the toolbar (52 pt, toolbar items over the column while shown), resizable by its leading edge
/// (300–560, the width the student dragged kept).
struct ExpandedAgentPanel: View {
    let model: AgentPanelModel
    let context: AgentContext
    let sendContext: @MainActor () -> AgentContext
    @Binding var width: Double

    @State private var isDropTargeted = false
    /// The width the student is dragging the column to (stored in `width` once it rests).
    @State private var dragged: Double?

    var body: some View {
        AgentPanelView(
            style: .expanded, model: model, context: context, sendContext: sendContext, maxHeight: .infinity,
            headerPlacement: .toolbar
        )
        // No minimum and a fixed ideal of its own: a long answer's one-line width (a table, a code
        // line) never becomes the column's, so `inspectorColumnWidth` alone sizes it.
        .frame(minWidth: 0, idealWidth: CGFloat(AgentPanelMetrics.idealWidth), maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ExpandedPanelBackground() }
        .overlay {
            if isDropTargeted {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).ignoresSafeArea()
            }
        }
        .agentFileDrop(model: model, isTargeted: $isDropTargeted)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            // Only the student's drag of the column's leading edge is kept: not a window resize, a
            // sidebar shown or hidden, or a narrower opening the window allowed.
            guard Self.isDraggingColumn else { return }
            let rounded = Double(newWidth.rounded())
            if rounded >= Double(AgentPanelMetrics.minWidth), abs(rounded - width) >= 1 { dragged = rounded }
        }
        .task(id: dragged) {
            // Stored once the drag rests (300 ms), not on every frame of it.
            guard let dragged else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, abs(dragged - width) >= 1 else { return }
            width = dragged
        }
    }

    /// The mouse is down and the window is not being resized: the column's divider is dragged.
    private static var isDraggingColumn: Bool {
        #if os(macOS)
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return false }
        let resizing = NSApp.keyWindow?.inLiveResize ?? false
        return !resizing
        #else
        return true
        #endif
    }
}

/// The column's opaque surface, as the compact panel's (mockup `.agent { background: var(--inspector) }`,
/// #f8f8fa / #222225), with a 0.5 pt hairline on its leading edge: nothing of the screen beside it
/// (Calendar's all-day band) shows through.
struct ExpandedPanelBackground: View {
    var body: some View {
        Rectangle()
            .fill(PanelSurface())
            .overlay(alignment: .leading) { Hairline(.vertical) }
            .ignoresSafeArea()
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
                maxHeight: CompactAgentPanel.maxHeight(windowHeight: windowHeight)
            )
            .modifier(CompactPanelChrome(isCachedDisplay: true))
        case .expanded:
            AgentPanelView(
                style: .expanded, model: model, context: context.settled, sendContext: { context }, maxHeight: .infinity,
                headerPlacement: .inline
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { ExpandedPanelBackground() }
        }
    }
}
