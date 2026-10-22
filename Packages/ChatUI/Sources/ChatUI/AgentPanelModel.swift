import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

/// One window's agent chat: where it shows, the conversation, the composer's text and files, the
/// message sent but not stored yet. The app owns it (`@State` in its root view) and hands it to
/// `.agentPanel(model:context:floatingLauncher:)`; on the Mac also to the Agent pane
/// (`AgentPane`, `AgentPaneAccessory`) and the floating panel (`AgentMiniChat`), so one
/// conversation is never on screen twice and the draft, files and conversation survive Expand and
/// Shrink. Every size shows the whole conversation; only a render may show some of its exchanges.
///
/// On the Mac the chat is the small floating chat (`mode` compact) or the Agent pane, which the
/// window's pane host opens and closes (`\.paneControl`): the small chat is hidden, never closed,
/// while the pane is open. On iOS the chat is the iPad's compact overlay or its trailing inspector
/// column (`mode` expanded).
@MainActor
@Observable
public final class AgentPanelModel {
    enum Mode: Hashable {
        case closed
        /// The small chat (the Mac's floating panel, the iPad's compact overlay).
        case compact
        #if os(iOS)
        /// The iPad's full-height trailing column.
        case expanded
        #endif
    }

    /// A request for the composer on screen to take the caret or give it back, kept until that
    /// composer takes it (one that appears later takes it then).
    struct ComposerRequest: Equatable {
        enum Action: Equatable {
            case focus
            case release
        }

        let action: Action
        /// Tells two requests of the same kind apart.
        let serial: Int
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
    /// The student asked something since the chat appeared: the prompt turns to "Ask a follow-up…".
    var askedSinceOpen = false
    /// Mirrors the composer's focus.
    var composerFocused = false
    /// The caret request the composer on screen has not taken yet.
    var composerRequest: ComposerRequest?
    @ObservationIgnored private var requestSerial = 0
    /// Memory… was picked in a title menu: `.agentPanel` presents the sheet (never a pane or the
    /// floating panel, which are other hosting views).
    var showsMemory = false
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
    /// What the app knows of where the student is (`.agentPanel` sets it).
    var appContext = AgentContext(screen: .other)
    /// What the screen on display publishes (`.agentContext`).
    var source: AgentContextSource?
    #if os(macOS)
    /// The window's panes (`\.paneControl`, from `.agentPanel`): the Agent pane is the expanded
    /// chat.
    var panes = PaneControl.none
    #endif
    let fixedNow: Date?

    public init(launch: AgentPanelLaunch = AgentPanelLaunch()) {
        switch launch.mode {
        case .closed:
            mode = .closed
        case .compact:
            mode = .compact
        case .expanded:
            #if os(iOS)
            mode = .expanded
            #else
            // The Agent pane is the pane host's (a render seeds its layout open); Shrink Chat then
            // shows the small chat.
            mode = .compact
            #endif
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

    /// The answer being written in `id` (one box per conversation, for this window's chat).
    func liveBox(for id: AgentConversation.ID) -> LiveReplyBox {
        if let box = liveBoxes[id] { return box }
        let box = LiveReplyBox()
        liveBoxes[id] = box
        return box
    }

    // MARK: Where it shows

    /// The small chat shows: compact, and on the Mac the Agent pane closed. The Mac app presents
    /// its floating panel by it.
    public var isMiniShown: Bool {
        #if os(macOS)
        mode == .compact && !isPaneOpen
        #else
        mode == .compact
        #endif
    }

    #if os(macOS)
    /// The window's Agent pane is open (the pane host's observed state).
    var isPaneOpen: Bool { panes.isOpen(.agent) }
    #endif

    /// The chat is on screen, small or expanded (the launcher is tinted).
    var isShown: Bool {
        #if os(macOS)
        mode == .compact || isPaneOpen
        #else
        mode != .closed
        #endif
    }

    /// The chat is expanded: the Agent pane (Mac) or the trailing column (iPad).
    var isExpanded: Bool {
        #if os(macOS)
        isPaneOpen
        #else
        mode == .expanded
        #endif
    }

    /// ⌘J hides something now (View ▸ Hide Chat): the small chat, or on the Mac the caret in the
    /// Agent pane's composer, which it gives back to the screen.
    var togglesOff: Bool {
        #if os(macOS)
        isPaneOpen ? composerFocused : mode == .compact
        #else
        mode != .closed
        #endif
    }

    /// The panel style whose composer takes caret requests: the one on screen.
    var shownStyle: AgentPanelView.Style? {
        if isExpanded { return .expanded }
        return mode == .compact ? .compact : nil
    }

    /// A message may go now: none is being handed over or waiting for its stored turn, the agent
    /// is not answering, no file is still being read.
    var canSendNow: Bool { !isSending && pending == nil && !isRunning && reading == 0 }

    /// The conversation on screen: a new chat's (nil until its first message), else the picked
    /// one, else the newest.
    func conversationID(newest: AgentConversation.ID?) -> AgentConversation.ID? {
        startsNew ? selected : (selected ?? newest)
    }

    // MARK: Opening and the caret

    /// Puts the caret in the composer on screen (the Agent pane's offer calls it once the pane is
    /// open), at the end of the kept draft.
    public func focusComposer() {
        request(.focus)
    }

    /// Gives the keyboard back to the screen (⌘J again, Esc in the Agent pane's composer).
    func releaseComposer() {
        request(.release)
    }

    private func request(_ action: ComposerRequest.Action) {
        requestSerial += 1
        composerRequest = ComposerRequest(action: action, serial: requestSerial)
    }

    /// ⌘J and the launcher. On the Mac, with the Agent pane open, the caret goes into its composer,
    /// and back to the screen when it is there already; else the small chat shows (the caret in
    /// its composer) or hides.
    func toggleChat() {
        #if os(macOS)
        if isPaneOpen {
            if composerFocused { releaseComposer() } else { focusComposer() }
            return
        }
        #endif
        if mode == .closed { open() } else { close() }
    }

    /// ⌘J, the launcher, Calendar's [+], a passage taken to the chat (`\.openAgentPanel`): the
    /// chat with the caret in its composer; `expanded`, the Agent pane (Mac) or the column (iPad).
    /// On the Mac an open Agent pane takes the caret instead of the small chat.
    func open(expanded: Bool = false) {
        #if os(macOS)
        if isPaneOpen {
            focusComposer()
        } else if expanded, panes.isInstalled {
            openPane()
        } else {
            if mode == .closed {
                askedSinceOpen = false
                mode = .compact
            }
            focusComposer()
        }
        #else
        if mode == .closed { askedSinceOpen = false }
        mode = expanded || mode == .expanded ? .expanded : .compact
        focusComposer()
        #endif
    }

    /// The small chat's ✕ (Hide Chat), Esc in its empty composer, ⌘J.
    func close() {
        mode = .closed
        composerFocused = false
    }

    /// ⌥⌘J, ⤢ / ⤡. On the Mac: Expand Chat opens the Agent pane under the room rules with the caret
    /// in its composer (the small chat hides with its draft, files and conversation kept); Shrink
    /// Chat closes the pane and shows the small chat. On the iPad: closed or compact → the column;
    /// the column → compact.
    func toggleExpanded() {
        #if os(macOS)
        if isPaneOpen {
            panes.close(.agent)
            mode = .compact
            focusComposer()
        } else if panes.isInstalled {
            openPane()
        } else {
            open()
        }
        #else
        switch mode {
        case .closed: open(expanded: true)
        case .compact: mode = .expanded
        case .expanded: mode = .compact
        }
        focusComposer()
        #endif
    }

    #if os(macOS)
    /// The Agent pane opens and its offer puts the caret in its composer.
    private func openPane() {
        if mode == .closed { askedSinceOpen = false }
        panes.open(.agent, true)
    }
    #endif

    func newChat() {
        startsNew = true
        selected = nil
        pending = nil
        askedSinceOpen = false
        choices += 1
        focusComposer()
    }

    /// A conversation from the title menu: the whole conversation, its latest question in sight.
    func pick(_ id: AgentConversation.ID) {
        choices += 1
        startsNew = false
        selected = id
        pending = nil
        askedSinceOpen = false
        notice = nil
        focusComposer()
    }

    // MARK: Context

    /// The context a message carries: the app's, with the screen's publication (and its
    /// `refine`, the playhead) merged over it, only while it is about the screen the app is on (a
    /// stale or foreign publication never names another screen: "Ask about your mail" on Mail).
    func sendContext() -> AgentContext {
        guard let source, source.context.screen == appContext.screen else { return appContext }
        return appContext.merging(source.current())
    }

    /// The context as the chat shows it (prompt, context lines): settled, no playhead.
    var shownContext: AgentContext {
        guard let source, source.context.screen == appContext.screen else { return appContext.settled }
        return appContext.merging(source.context).settled
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
