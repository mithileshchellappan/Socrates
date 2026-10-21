#if os(macOS)
import AppKit
import Capture
import CaptureUI
import Notes
import StudyCore
import StudyUI
import SwiftUI

// Everything in a note that is not plain text is a TextKit 2 attachment (one character) with a
// view provider: chips ("S13", "37:59"), inline media (images, sketches, slide clips), professor
// quotes, and blocks or runs the editor does not know (shown read-only, kept as they were). They
// move, select, delete, copy and undo like characters (DESIGN 8.4). A large one is as wide as
// the line, so it takes its own line inside its paragraph and never floats.

/// What an attachment shows and how big it is. The state lives on the main actor; the
/// `NSTextAttachment` (`NoteTextAttachment`) only carries it. Public (ln): the lecture notes
/// (StudyPageUI) draw their figures, chips and kept answers with the same machinery.
@MainActor
public protocol TextAttachmentContent: AnyObject, Sendable {
    /// The attachment's view (hosted SwiftUI).
    func makeView() -> NSView?
    /// Bounds relative to the baseline, for a line `lineWidth` wide.
    func bounds(lineWidth: CGFloat, view: NSView?) -> CGRect
}

/// A note's attachment: it knows its editor's context.
@MainActor
protocol NoteAttachmentContent: TextAttachmentContent {
    var context: NoteEditorContext? { get }
}

extension NoteAttachmentContent {
    /// The hosted view, with the screen's environment the attachment views need.
    func host<Content: View>(_ content: Content, hitWidth: CGFloat? = nil) -> NSView {
        let view = NoteAttachmentHostingView(rootView: AnyView(content.environment(\.studyServices, context?.services)))
        view.hitWidth = hitWidth
        return view
    }
}

/// One character of a note's text that shows a view (`content`).
public final class NoteTextAttachment: NSTextAttachment {
    public let content: any TextAttachmentContent

    public init(_ content: any TextAttachmentContent) {
        self.content = content
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }

    public required init?(coder: NSCoder) { nil }

    /// Nothing under the view (TextKit otherwise draws a generic file icon there).
    override public func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?) -> NSImage? {
        NSImage(size: NSSize(width: 1, height: 1))
    }

    override public func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = NoteAttachmentViewProvider(
            textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class NoteAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let content = (textAttachment as? NoteTextAttachment)?.content
        view = MainActor.assumeIsolated {
            content?.makeView()
        }
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        let content = (textAttachment as? NoteTextAttachment)?.content
        let view = view
        let width = proposedLineFragment.width
        return MainActor.assumeIsolated {
            content?.bounds(lineWidth: width, view: view) ?? .zero
        }
    }
}

/// A hosting view that takes clicks only over its content's leading `hitWidth` (a line-wide
/// attachment's empty end belongs to the text).
public final class NoteAttachmentHostingView: NSHostingView<AnyView> {
    public var hitWidth: CGFloat?

    override public func hitTest(_ point: NSPoint) -> NSView? {
        if let hitWidth, let superview {
            let local = convert(point, from: superview)
            if local.x > hitWidth { return nil }
        }
        return super.hitTest(point)
    }
}

/// The room a line-wide attachment leaves at its top and bottom.
private let mediaMargin: CGFloat = 3

/// A media size fitted into a line `lineWidth` wide (never wider than stored × the content zoom).
@MainActor
private func fitted(width: Double?, height: Double?, zoom: CGFloat, lineWidth: CGFloat) -> CGSize {
    let w = CGFloat(width ?? 256) * zoom
    let h = CGFloat(height ?? 144) * zoom
    guard w > 0, h > 0 else { return CGSize(width: 1, height: 1) }
    let scale = min(1, max(1, lineWidth - 2) / w)
    return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
}

// MARK: - Chips

/// "S13" or "37:59": `SlideChip` / `TimeChip`, one character.
@MainActor
final class ChipAttachment: NoteAttachmentContent {
    weak var context: NoteEditorContext?
    let inline: NoteInline
    /// The chip's size at 100 % (it is drawn × the content zoom).
    private var size: CGSize?

    init(inline: NoteInline, context: NoteEditorContext?) {
        self.inline = inline
        self.context = context
    }

    func makeView() -> NSView? {
        let zoom = context?.metrics.zoom ?? 1
        let view = host(NoteChipView(inline: inline, context: context))
        let fitting = view.fittingSize
        size = CGSize(width: fitting.width / zoom, height: fitting.height / zoom)
        return view
    }

    func bounds(lineWidth: CGFloat, view: NSView?) -> CGRect {
        let zoom = context?.metrics.zoom ?? 1
        let size = size ?? CGSize(width: 36, height: 15)
        return CGRect(x: 0, y: -3.5 * zoom, width: ceil(size.width * zoom) + 1, height: ceil(size.height * zoom))
    }
}

struct NoteChipView: View {
    let inline: NoteInline
    let context: NoteEditorContext?

    var body: some View {
        let source = inline.source ?? SourceRef(kind: inline.type == .timeRef ? .transcript : .slide)
        Group {
            if inline.type == .timeRef, let time = source.time {
                TimeChip(time, showsPlayGlyph: true) { context?.activate(.time(source)) }
            } else if inline.type == .slideRef, let page = source.pageNumber {
                SlideChip(page: page) { context?.activate(.slide(source)) }
            } else {
                Text(verbatim: inline.text)
                    .font(.chip)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .zoomScaled(context?.metrics.zoom ?? 1)
    }
}

// MARK: - Media

/// An image, a sketch or a slide clip: inline in a paragraph (`inline`), or an older note's block
/// of its own (`block`, kept as such).
@MainActor
final class MediaAttachment: NoteAttachmentContent {
    weak var context: NoteEditorContext?
    private let inline: NoteInline?
    private let block: NoteBlock?
    /// The file shown (a sketch's changes when the student draws on it).
    private(set) var media: NoteAttachment
    let source: SourceRef?
    /// A sketch's strokes, loaded on first display.
    var drawing: InkDrawing?

    init(inline: NoteInline, context: NoteEditorContext?) {
        self.inline = inline
        block = nil
        media = inline.attachment ?? NoteAttachment(kind: .image, blobSHA256: "", blobPath: "")
        source = inline.source
        self.context = context
    }

    init(block: NoteBlock, context: NoteEditorContext?) {
        inline = nil
        self.block = block
        let kind: NoteAttachment.Kind = block.type == .drawing ? .drawing : block.type == .slide ? .slide : .image
        media = block.attachment ?? NoteAttachment(kind: kind, blobSHA256: "", blobPath: "")
        source = block.source
        self.context = context
    }

    /// A sketch drawn in the editor.
    init(sketch: NoteAttachment, drawing: InkDrawing, context: NoteEditorContext?) {
        inline = NoteMedia.inline(sketch)
        block = nil
        media = sketch
        source = nil
        self.drawing = drawing
        self.context = context
    }

    var kind: NoteAttachment.Kind {
        if let block, block.attachment == nil {
            return block.type == .drawing ? .drawing : block.type == .slide ? .slide : .image
        }
        return media.kind
    }

    /// The inline as it is now (nil for a block).
    var currentInline: NoteInline? {
        guard var inline else { return nil }
        if inline.attachment != nil { inline.attachment = media }
        return inline
    }

    /// The block as it is now (nil for an inline).
    var currentBlock: NoteBlock? {
        guard var block else { return nil }
        if block.attachment != nil { block.attachment = media }
        return block
    }

    /// The student drew on the sketch: the new strokes are stored as a new blob.
    @MainActor func update(drawing: InkDrawing) {
        guard drawing != self.drawing else { return }
        self.drawing = drawing
        guard let blobs = context?.services?.blobs else { return }
        Task { @MainActor [weak self] in
            let stored = await Self.store(drawing, blobs: blobs)
            guard let self, let stored, self.drawing == drawing else { return }
            self.media = stored
            self.context?.edited()
        }
    }

    @concurrent
    nonisolated private static func store(_ drawing: InkDrawing, blobs: BlobStore) async -> NoteAttachment? {
        do {
            return try NoteMedia.storeSketch(drawing, blobs: blobs)
        } catch {
            NotesLog.logger.error("Saving a sketch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func makeView() -> NSView? {
        let width = CGFloat(media.width ?? 256) * (context?.metrics.zoom ?? 1)
        switch kind {
        case .drawing:
            if drawing == nil, let services = context?.services {
                drawing = NoteMedia.drawing(of: media, blobs: services.blobs)
            }
            return host(NoteSketchView(attachment: self, context: context), hitWidth: width)
        case .slide:
            return host(NoteSlideClipView(media: media, source: source, context: context), hitWidth: width)
        default:
            return host(NoteImageView(media: media, context: context), hitWidth: width)
        }
    }

    func bounds(lineWidth: CGFloat, view: NSView?) -> CGRect {
        let size = fitted(width: media.width, height: media.height, zoom: context?.metrics.zoom ?? 1, lineWidth: lineWidth)
        (view as? NoteAttachmentHostingView)?.hitWidth = size.width
        return CGRect(x: 0, y: -4, width: max(1, floor(lineWidth) - 1), height: size.height + 2 * mediaMargin)
    }
}

/// An image at its display size, downsampled.
struct NoteImageView: View {
    let media: NoteAttachment
    let context: NoteEditorContext?
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        NoteMediaFrame(media: media, zoom: context?.metrics.zoom ?? 1) { size in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .task(id: "\(media.blobSHA256)@\(Int(size.width))") { await load(size) }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Image"))
        .accessibilityAddTraits(.isImage)
    }

    /// Decodes the image at the size it is drawn (its longer side at the display's scale).
    private func load(_ size: CGSize) async {
        guard let services = context?.services, !media.blobPath.isEmpty else { return }
        let pixels = Int(max(size.width, size.height) * max(displayScale, 2))
        image = await NoteImageCache.image(at: services.blobs.url(for: media.blob), sha: media.blobSHA256, maxPixelSize: max(64, pixels))
    }
}

/// Lays a medium out at its fitted size (× the content zoom), leading, with the line's margins.
struct NoteMediaFrame<Content: View>: View {
    let media: NoteAttachment
    var zoom: CGFloat = 1
    @ViewBuilder let content: (CGSize) -> Content
    @State private var lineWidth: CGFloat = 0

    var body: some View {
        let size = fittedSize
        content(size)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, mediaMargin)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lineWidth = $0 }
    }

    private var fittedSize: CGSize {
        let w = CGFloat(media.width ?? 256) * zoom
        let h = CGFloat(media.height ?? 144) * zoom
        guard w > 0, h > 0 else { return CGSize(width: 1, height: 1) }
        let scale = lineWidth > 0 ? min(1, max(1, lineWidth - 2) / w) : 1
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }
}

/// A slide clip: the page drawn from the deck's PDF, an opaque `SlideChip` in its corner; a
/// click opens the slide.
struct NoteSlideClipView: View {
    let media: NoteAttachment
    let source: SourceRef?
    let context: NoteEditorContext?
    @State private var deck: SlideDeck?

    var body: some View {
        let zoom = context?.metrics.zoom ?? 1
        NoteMediaFrame(media: media, zoom: zoom) { size in
            ZStack(alignment: .topTrailing) {
                if let deck, let page = source?.pageNumber {
                    SlideImageView(deck: deck, page: page, pixelWidth: 640, cornerRadius: 10)
                        .frame(width: size.width, height: size.height)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white)
                        .frame(width: size.width, height: size.height)
                }
                if let page = source?.pageNumber {
                    SlideChip(page: page, action: open)
                        .background(Color.contentBackground, in: Capsule())
                        .zoomScaled(zoom)
                        .padding(5 * zoom)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
        .task(id: media.blobSHA256) {
            guard let services = context?.services, !media.blobPath.isEmpty else { return }
            deck = NoteDeckCache.cached(sha: media.blobSHA256)
            if deck == nil { deck = await NoteDeckCache.deck(blob: media.blob, services: services) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Slide \(source?.pageNumber ?? 0)"))
        .accessibilityAddTraits(.isButton)
    }

    private func open() {
        guard let source else { return }
        context?.activate(.slide(source))
    }
}

/// A sketch on the canvas surface. A click draws on it in place (`InkCanvas`, with a small pen,
/// highlighter and eraser strip); Esc or a click in the text ends it.
struct NoteSketchView: View {
    let attachment: MediaAttachment
    let context: NoteEditorContext?
    @State private var drawing: InkDrawing
    @State private var tool: InkTool = .pen
    @Environment(\.colorScheme) private var colorScheme

    init(attachment: MediaAttachment, context: NoteEditorContext?) {
        self.attachment = attachment
        self.context = context
        let media = attachment.media
        _drawing = State(initialValue: attachment.drawing ?? InkDrawing(width: media.width ?? 262, height: media.height ?? 178))
    }

    private var isEditing: Bool {
        context?.editingSketch == ObjectIdentifier(attachment)
    }

    var body: some View {
        NoteMediaFrame(media: attachment.media, zoom: context?.metrics.zoom ?? 1) { size in
            ZStack(alignment: .bottomTrailing) {
                Color.canvasBackground(colorScheme)
                if isEditing {
                    InkCanvas(drawing: $drawing, tool: tool, surface: .sketch)
                        .id(ObjectIdentifier(attachment))
                    NoteSketchTools(tool: $tool)
                        .padding(6)
                } else {
                    InkView(drawing: drawing, surface: .sketch)
                        .contentShape(Rectangle())
                        .onTapGesture { context?.beginEditing(ObjectIdentifier(attachment)) }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isEditing ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isEditing ? 1 : 0.5)
            )
        }
        .onChange(of: drawing) { _, drawing in
            attachment.update(drawing: drawing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sketch"))
    }
}

/// Pen, highlighter, eraser while a sketch is drawn on.
private struct NoteSketchTools: View {
    @Binding var tool: InkTool

    var body: some View {
        HStack(spacing: 2) {
            button(.pen, "Pen", "pencil.tip")
            button(.highlighter, "Highlighter", "highlighter")
            button(.eraser, "Eraser", "eraser")
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private func button(_ value: InkTool, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Button {
            tool = value
        } label: {
            Image(systemName: symbol)
                .imageScale(.small)
                .frame(width: 24, height: 20)
                .foregroundStyle(tool == value ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background(tool == value ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Quotes

/// A professor quote (its own block): 3 pt amber bar, “quote”, by-line of pin + "Prof.
/// Example" + `TimeChip` at 12 secondary (mockup 04's `.tq`).
@MainActor
final class QuoteAttachment: NoteAttachmentContent {
    weak var context: NoteEditorContext?
    let block: NoteBlock

    init(block: NoteBlock, context: NoteEditorContext?) {
        self.block = block
        self.context = context
    }

    func makeView() -> NSView? {
        host(NoteQuoteView(block: block, context: context))
    }

    func bounds(lineWidth: CGFloat, view: NSView?) -> CGRect {
        let metrics = context?.metrics ?? NoteMetrics(style: .document)
        let zoom = metrics.zoom
        let width = max(40, floor(lineWidth) - 1)
        let text = "“\(block.text)”" as NSString
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(0, metrics.lineHeight - 17 * zoom)
        let rect = text.boundingRect(
            with: CGSize(width: width - 15 * zoom, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: metrics.bodySize), .paragraphStyle: style]
        )
        let height = ceil(rect.height) + (4 + 18 + 2) * zoom + 2 * mediaMargin
        return CGRect(x: 0, y: -4, width: width, height: height)
    }
}

struct NoteQuoteView: View {
    let block: NoteBlock
    let context: NoteEditorContext?

    var body: some View {
        let metrics = context?.metrics ?? NoteMetrics(style: .document)
        let zoom = metrics.zoom
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.professor)
                .frame(width: 3 * zoom)
            VStack(alignment: .leading, spacing: 4 * zoom) {
                Text(verbatim: "“\(block.text)”")
                    .font(.system(size: metrics.bodySize))
                    .lineSpacing(max(0, metrics.lineHeight - 17 * zoom))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6 * zoom) {
                    ProvenancePin(.professor)
                        .zoomScaled(zoom)
                    if let professor = context?.professor {
                        Text(verbatim: professor)
                    }
                    if let source = block.source, let time = source.time {
                        TimeChip(time, showsPlayGlyph: true) { context?.activate(.time(source)) }
                            .zoomScaled(zoom)
                    }
                }
                .font(.system(size: 12 * zoom))
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 12 * zoom)
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, mediaMargin)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Claude's words

/// The one sparkle before a paragraph's first words that Claude wrote (ln, Edit as Note: the `ai`
/// mark). Drawn, never stored: the note's blocks read it as nothing, and it comes back on the next
/// load only while the paragraph still holds Claude's words.
@MainActor
final class AISparkleAttachment: NoteAttachmentContent {
    weak var context: NoteEditorContext?

    init(context: NoteEditorContext?) {
        self.context = context
    }

    func makeView() -> NSView? {
        host(NoteAISparkleView(context: context))
    }

    func bounds(lineWidth: CGFloat, view: NSView?) -> CGRect {
        let size = context?.metrics.bodySize ?? 14
        return CGRect(x: 0, y: -2 * (context?.metrics.zoom ?? 1), width: size + 4, height: size)
    }
}

/// The sparkle at the body size (it follows the content zoom).
struct NoteAISparkleView: View {
    let context: NoteEditorContext?

    var body: some View {
        let size = context?.metrics.bodySize ?? 14
        Image(systemName: "sparkle")
            .font(.system(size: size - 1))
            .foregroundStyle(Color.ai)
            .frame(width: size, height: size, alignment: .leading)
            .accessibilityLabel(Text("AI"))
    }
}

// MARK: - Kept as they were

/// A block or run of a kind the editor does not know (or a divider): shown as its text,
/// read-only, written back unchanged.
@MainActor
final class KeptAttachment: NoteAttachmentContent {
    weak var context: NoteEditorContext?
    let inline: NoteInline?
    let block: NoteBlock?
    /// An inline's size at 100 % (it is drawn × the content zoom).
    private var size: CGSize?

    init(inline: NoteInline, context: NoteEditorContext?) {
        self.inline = inline
        block = nil
        self.context = context
    }

    init(block: NoteBlock, context: NoteEditorContext?) {
        inline = nil
        self.block = block
        self.context = context
    }

    func makeView() -> NSView? {
        if let block {
            return host(NoteKeptBlockView(block: block, context: context))
        }
        let zoom = context?.metrics.zoom ?? 1
        let view = host(NoteKeptInlineView(text: inline?.text ?? "", context: context))
        let fitting = view.fittingSize
        size = CGSize(width: fitting.width / zoom, height: fitting.height / zoom)
        return view
    }

    func bounds(lineWidth: CGFloat, view: NSView?) -> CGRect {
        if let block {
            let width = max(40, floor(lineWidth) - 1)
            guard block.type != .divider else { return CGRect(x: 0, y: -4, width: width, height: 13) }
            let rect = (block.text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: context?.metrics.bodySize ?? 14)]
            )
            return CGRect(x: 0, y: -4, width: width, height: max(17 * (context?.metrics.zoom ?? 1), ceil(rect.height)) + 2)
        }
        let zoom = context?.metrics.zoom ?? 1
        let size = size ?? .zero
        return CGRect(x: 0, y: -4 * zoom, width: ceil(size.width * zoom), height: ceil(size.height * zoom))
    }
}

/// A run the editor does not know, as its text in grey at the body size.
struct NoteKeptInlineView: View {
    let text: String
    let context: NoteEditorContext?

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: context?.metrics.bodySize ?? 14))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

struct NoteKeptBlockView: View {
    let block: NoteBlock
    let context: NoteEditorContext?

    var body: some View {
        if block.type == .divider {
            Hairline()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(verbatim: block.text)
                .font(.system(size: context?.metrics.bodySize ?? 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
