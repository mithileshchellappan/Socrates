import PhotosUI
import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// M7, the iPhone (docs/plan-m7.md §5.2.4; agent panel mockup §7 "the same panel as a sheet"):
// the agent panel as a sheet with two heights. The conversation is the Mac's (one `app`
// conversation, the same rows); AI runs on the Mac only, so a question goes as an `agent_request`
// row (`AgentPanelActions.relay`) and the answer arrives as the conversation's turns through
// iCloud sync. Without the relay's `isAvailable` the shell has no launcher and nothing shows.

/// How the sheet starts (renders: `tools/parity` and the integrator's phone parity routes).
public struct AgentSheetLaunch: Hashable, Sendable {
    public enum Detent: Hashable, Sendable {
        /// 356 pt over Today and the tab bar: the conversation, scrolled as the panel.
        case small
        /// The whole conversation.
        case large
    }

    public var detent: Detent
    /// The conversation shown; nil: the most recently active `app` conversation.
    public var conversationID: AgentConversation.ID?
    /// An empty New Chat instead of a conversation.
    public var newChat: Bool
    /// Renders only: the exchanges shown (0-based; mockup §7 draws the first one); nil: the
    /// whole conversation, as the sheet shows it.
    public var exchanges: Range<Int>?
    /// Text in the composer.
    public var draft: String
    /// A fixed "now" (the history menu's days); nil follows the clock.
    public var now: Date?

    public init(
        detent: Detent = .small, conversationID: AgentConversation.ID? = nil, newChat: Bool = false, exchanges: Range<Int>? = nil,
        draft: String = "", now: Date? = nil
    ) {
        self.detent = detent
        self.conversationID = conversationID
        self.newChat = newChat
        self.exchanges = exchanges
        self.draft = draft
        self.now = now
    }
}

/// The agent on the iPhone (agent panel mockup §7): a sheet with two detents, small (356 pt: the
/// conversation scrolled as the panel, the composer, Today above it still usable) and large (the
/// whole conversation, Today dimmed);the opaque content surface at both heights (answers are content, never glass);
/// the title row's menu (recent conversations by day, New Chat, Memory…); the panel's thread rows
/// at the sheet's sizes; the composer with the paperclip menu (Photo Library, Take Photo where a
/// camera exists, Choose File…) and Paste in the field. Present it from the shell's bubble:
///
///     .sheet(isPresented: $showsAgent) { AgentSheet(context: context) }
public struct AgentSheet: View {
    /// The small detent's height (mockup §7: 356 of 844).
    public static let smallHeight: CGFloat = 356

    private let context: AgentContext
    @Environment(\.agentPanelActions) private var actions
    @State private var model: AgentPanelModel
    @State private var detent: PresentationDetent
    @State private var showsMemory = false
    private let historyQuery: FetchAll<AgentConversation>

    /// - Parameters:
    ///   - context: what the tab on screen shows (Today: `.today`); the prompt names it and the
    ///     question carries it.
    ///   - launch: the detent and conversation it starts on (renders).
    public init(context: AgentContext, launch: AgentSheetLaunch = AgentSheetLaunch()) {
        self.context = context
        _model = State(initialValue: AgentPanelModel(launch: AgentPanelLaunch(
            mode: .compact, conversationID: launch.conversationID, newChat: launch.newChat, exchanges: launch.exchanges, draft: launch.draft,
            now: launch.now
        )))
        _detent = State(initialValue: launch.detent == .large ? .large : .height(Self.smallHeight))
        historyQuery = FetchAll(
            AgentConversation.where { $0.kind.eq(ConversationKind.app) }.order { $0.createdAt.desc() }.limit(AgentPanelView.historyLimit)
        )
    }

    private var history: [AgentConversation] { historyQuery.wrappedValue }

    private var newest: AgentConversation.ID? {
        history.max { $0.updatedAt < $1.updatedAt }?.id
    }

    public var body: some View {
        let model = model
        let conversationID = model.conversationID(newest: newest)
        let shown = context.settled
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                AgentTitleMenu(
                    model: model, history: history, conversationID: conversationID, fontSize: 17, chevronSize: 11, showsMemory: $showsMemory
                )
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .padding(.top, 10)
            // Both heights show the whole conversation, scrolled as the panel (its latest question
            // in sight).
            AgentThreadView(style: .sheet, conversationID: conversationID, model: model, context: shown, maxHeight: .infinity)
                .id(conversationID)
            SheetComposer(model: model, prompt: prompt) {
                send(to: conversationID)
            }
            if let notice = model.notice {
                Text(verbatim: notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.agentThreadMetrics, .sheet)
        .sheet(isPresented: $showsMemory) {
            ChatMemorySheet()
        }
        .presentationDetents([.height(Self.smallHeight), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // Opaque at both heights: answers are content (glass stays on the tab bar and Record).
        .presentationBackground(Color.contentBackground)
        // At the small height Today above stays usable (its Start); the large one dims it.
        .presentationBackgroundInteraction(.enabled(upThrough: .height(Self.smallHeight)))
    }

    /// The prompt names the tab ("Ask about today"); after a question here "Ask a follow-up…".
    private var prompt: Text {
        if model.askedSinceOpen || model.pending != nil { return Text("Ask a follow-up…") }
        return AgentPanelView.prompt(for: context)
    }

    /// Send: the question goes as a request for the Mac (the relay); it may go while earlier ones
    /// wait or the Mac answers (they queue up there), one hand-over at a time.
    private func send(to conversationID: AgentConversation.ID?) {
        guard model.pending == nil else { return }
        model.send(to: conversationID, context: context, actions: actions)
    }
}

// MARK: - Composer

/// The sheet's composer (mockup §7 `.s-comp`): files waiting as tiles above, then [the paperclip
/// (38 pt circle on the quiet fill) | the field (38 pt, radius 19, a 0.5 pt ring, 15 pt) with
/// Send at its end, only with words or a file].
struct SheetComposer: View {
    let model: AgentPanelModel
    let prompt: Text
    let send: () -> Void

    @Environment(\.studyServices) private var services
    @State private var showsPhotos = false
    @State private var showsImporter = false
    @State private var showsCamera = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var isFocused = false

    private var hasText: Bool { !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { (hasText || model.hasFiles) && model.pending == nil && !model.isSending && model.reading == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.hasFiles || model.reading > 0 {
                TileFlow(spacing: 8) {
                    ForEach(model.attachments) { attachment in
                        ComposerAttachmentTile(attachment: attachment) { model.remove(attachment) }
                    }
                    ForEach(0..<model.reading, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(QuietFill())
                            .frame(width: 40, height: 40)
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 6)
            }
            HStack(alignment: .bottom, spacing: 10) {
                paperclip
                field
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .photosPicker(
            isPresented: $showsPhotos, selection: $photos, maxSelectionCount: max(1, AgentAttachment.maximumPerMessage - model.attachments.count),
            matching: .images
        )
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            attach(items)
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: AttachmentTypes.accepted, allowsMultipleSelection: true) { result in
            guard let services, case .success(let urls) = result else { return }
            model.attach(urls: urls, blobs: services.blobs)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in
                guard let services else { return }
                model.attach(data: data, type: .jpeg, fileName: String(localized: "Photo") + ".jpeg", blobs: services.blobs)
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private var paperclip: some View {
        Menu {
            Button {
                showsPhotos = true
            } label: {
                Label("Photo Library", systemImage: "photo")
            }
            if CameraPicker.isAvailable {
                Button {
                    showsCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            Button {
                showsImporter = true
            } label: {
                Label("Choose File…", systemImage: "folder")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(QuietFill(), in: Circle())
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .disabled(!model.canAttach)
        .accessibilityLabel(Text("Attach"))
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        return HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    prompt
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                draftField
            }
            if canSend {
                Button(action: send) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 26))
                        .foregroundStyle(.tint)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, canSend ? 4 : 14)
        .frame(minHeight: 38)
        .background(Color.contentBackground, in: shape)
        .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
        .onChange(of: isFocused) { _, focused in model.composerFocused = focused }
        .onChange(of: model.focusRequests) { isFocused = true }
    }

    @ViewBuilder
    private var draftField: some View {
        let binding = Binding(get: { model.draft }, set: { text in
            model.draft = text
            if model.notice != nil { model.notice = nil }
        })
        #if os(iOS)
        // Paste of a photo, a screenshot or a PDF becomes a tile; text pastes as text.
        PastingTextField(text: binding, isFocused: $isFocused, maxLines: 6) { providers in
            guard let services else { return }
            AgentItemProviders.attach(providers, model: model, blobs: services.blobs)
        }
        .accessibilityLabel(prompt)
        #else
        TextField("", text: binding, prompt: prompt, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.subheadline)
            .lineLimit(1...6)
            .padding(.vertical, 9)
        #endif
    }

    /// Photos from the library: their bytes as the library has them (HEIC, JPEG, PNG).
    private func attach(_ items: [PhotosPickerItem]) {
        guard let services else { return }
        let blobs = services.blobs
        let model = model
        for item in items.prefix(max(0, AgentAttachment.maximumPerMessage - model.attachments.count)) {
            let type = item.supportedContentTypes.first { AgentAttachment.kind(for: $0) == .image } ?? .jpeg
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let ext = type.preferredFilenameExtension ?? "jpeg"
                    model.attach(data: data, type: type, fileName: String(localized: "Photo") + ".\(ext)", blobs: blobs)
                } catch {
                    ChatUILog.ui.notice("A photo could not be read: \(String(describing: error), privacy: .public)")
                    model.notice = String(localized: "The photo can’t be read.")
                }
            }
        }
    }
}

// MARK: - Pasted files

/// Files and images pasted into the sheet's field (iOS): each provider's first type the accept
/// rule takes (an image, a PDF, text or code; TIFF becomes PNG) becomes a tile.
enum AgentItemProviders {
    @MainActor
    static func attach(_ providers: [NSItemProvider], model: AgentPanelModel, blobs: BlobStore) {
        for provider in providers {
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            guard let type = types.first(where: { AgentAttachment.kind(for: $0) != nil && !$0.conforms(to: .plainText) })
                ?? types.first(where: { $0.conforms(to: .tiff) })
            else { continue }
            let name = provider.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? String(localized: "Pasted")
            let fileName = name + "." + (type.preferredFilenameExtension ?? "dat")
            _ = provider.loadDataRepresentation(for: type) { data, error in
                Task { @MainActor in
                    guard let data else {
                        ChatUILog.ui.notice("A pasted file could not be read: \(String(describing: error), privacy: .public)")
                        return
                    }
                    model.attach(data: data, type: type, fileName: fileName, blobs: blobs)
                }
            }
        }
    }
}

// MARK: - iOS pieces

#if os(iOS)
/// The sheet's field (1–6 lines, 15 pt): a text view that also takes a pasted photo, screenshot
/// or PDF (SwiftUI's field pastes text only on iOS), handed to `pasteFiles`.
struct PastingTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let maxLines: Int
    let pasteFiles: @MainActor ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> PasteAwareTextView {
        let view = PasteAwareTextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .subheadline)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.pasteFiles = pasteFiles
        view.text = text
        return view
    }

    func updateUIView(_ view: PasteAwareTextView, context: Context) {
        context.coordinator.parent = self
        view.pasteFiles = pasteFiles
        if view.text != text { view.text = text }
        if isFocused, !view.isFirstResponder {
            view.becomeFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteAwareTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 18
        let limit = lineHeight * CGFloat(maxLines) + uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let scrolls = fitting.height > limit
        if uiView.isScrollEnabled != scrolls { uiView.isScrollEnabled = scrolls }
        return CGSize(width: width, height: min(fitting.height, limit))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PastingTextField

        init(parent: PastingTextField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

/// Offers Paste for a photo, a screenshot or a PDF on the pasteboard (metadata only: nothing is
/// read until the student pastes) and hands those to `pasteFiles`; text pastes as text.
final class PasteAwareTextView: UITextView {
    var pasteFiles: (@MainActor ([NSItemProvider]) -> Void)?

    private static let fileTypes = [UTType.pdf, .png, .jpeg, .heic, .gif, .webP, .tiff].map(\.identifier)

    private var hasFiles: Bool {
        let board = UIPasteboard.general
        return board.hasImages || board.contains(pasteboardTypes: Self.fileTypes)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), hasFiles { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if !board.hasStrings, hasFiles, let pasteFiles {
            pasteFiles(board.itemProviders)
            return
        }
        super.paste(sender)
    }
}

/// Take Photo: the camera, full screen; the photo as JPEG.
struct CameraPicker: UIViewControllerRepresentable {
    let take: @MainActor (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The device has a camera (never in the simulator).
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(take: take, dismiss: { dismiss() })
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let take: @MainActor (Data) -> Void
        let dismiss: @MainActor () -> Void

        init(take: @escaping @MainActor (Data) -> Void, dismiss: @escaping @MainActor () -> Void) {
            self.take = take
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) {
                take(data)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
#else
/// No camera menu item off iOS.
enum CameraPicker {
    static let isAvailable = false
}
#endif
