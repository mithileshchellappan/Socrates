import CoreGraphics
import ImageIO
import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// Files for the agent (ma, docs/plan-agent.md §4, §6; mockup §4): the three kinds Claude Code
// reads (images, PDFs, text and code). They come in by drop on the panel, ⌘V or the paperclip,
// wait in the composer as tiles (× on hover) and ride above the sent message as small tiles.
// Thumbnails are downsampled with ImageIO off the main actor, never decoded at full size.

/// The types the paperclip's open panel offers (the accept rule: `AgentAttachment.kind(for:)`).
enum AttachmentTypes {
    static let accepted: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .pdf, .text, .sourceCode, .json]
}

/// Image work for attachments, off the main actor.
enum AttachmentImages {
    /// A thumbnail whose long edge is `maxPixel`, with the image's orientation applied.
    @concurrent
    static func thumbnail(at url: URL, maxPixel: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The same from bytes (a phone question's file, kept in its row).
    @concurrent
    static func thumbnail(data: Data, maxPixel: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A PDF's pages from its bytes.
    static func pageCount(pdf data: Data) -> Int? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return nil }
        return document.numberOfPages
    }

    /// PNG bytes of any image ImageIO reads (a TIFF screenshot on the pasteboard).
    static func png(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

/// An image attachment's thumbnail with a hairline edge (light and dark), filling its frame.
struct AttachmentThumbnail: View {
    let attachment: AgentAttachment
    let radius: CGFloat

    @Environment(\.studyServices) private var services
    @Environment(\.displayScale) private var displayScale
    @Environment(\.agentThreadMetrics) private var metrics
    @State private var image: CGImage?

    /// The long edge it is drawn at (the sheet's 72 pt photos need more than 48).
    private var maxPoints: CGFloat { max(metrics.imageTile.width, metrics.imageTile.height) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            Rectangle().fill(QuietFill())
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
        }
        .task(id: attachment.blob.sha256) {
            guard let services else { return }
            let url = services.blobs.url(for: attachment.blob)
            image = await AttachmentImages.thumbnail(at: url, maxPixel: Int(max(48, maxPoints) * max(1, displayScale)))
        }
    }
}

/// What a tile says under a file's name: "3 pages", "1 KB".
enum AttachmentText {
    static func detail(_ attachment: AgentAttachment) -> String? {
        switch attachment.kind {
        case .pdf:
            guard let pages = attachment.pageCount else { return nil }
            return pages == 1 ? String(localized: "1 page") : String(localized: "\(pages) pages")
        case .text:
            return ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
        case .image:
            return nil
        }
    }

    static func glyph(_ attachment: AgentAttachment) -> String {
        switch attachment.kind {
        case .pdf: "doc.richtext"
        case .text: "doc.plaintext"
        case .image: "photo"
        }
    }
}

/// A file in the composer: an image as a 40 pt thumbnail; a PDF or text file as [glyph | name over
/// "3 pages" / "1 KB"] on the raised surface; × on hover removes it.
struct ComposerAttachmentTile: View {
    let attachment: AgentAttachment
    let remove: () -> Void

    @State private var isHovered = false

    /// No hover on the phone: × always shows there.
    private var showsRemove: Bool {
        #if os(iOS)
        true
        #else
        isHovered
        #endif
    }

    var body: some View {
        tile
            .overlay(alignment: .topLeading) {
                if showsRemove {
                    Button(action: remove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Color.contentBackground)
                            .frame(width: 16, height: 16)
                            .background(.secondary, in: Circle())
                            .overlay { Circle().strokeBorder(Color.contentBackground, lineWidth: 1.5) }
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                    .accessibilityLabel(Text("Remove"))
                }
            }
            .onHover { isHovered = $0 }
            .help(Text(verbatim: attachment.fileName))
    }

    @ViewBuilder
    private var tile: some View {
        switch attachment.kind {
        case .image:
            AttachmentThumbnail(attachment: attachment, radius: 10)
                .frame(width: 40, height: 40)
        case .pdf, .text:
            HStack(spacing: 6) {
                Image(systemName: AttachmentText.glyph(attachment))
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: attachment.fileName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = AttachmentText.detail(attachment) {
                        Text(verbatim: detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 40)
            .frame(maxWidth: 200, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
        }
    }
}

/// A file on a sent message: an image as a small thumbnail; a PDF as its name and "3 pages"; a
/// text file as its name and size (28 pt).
struct SentAttachmentTile: View {
    let attachment: AgentAttachment

    @Environment(\.agentThreadMetrics) private var metrics

    var body: some View {
        switch attachment.kind {
        case .image:
            AttachmentThumbnail(attachment: attachment, radius: metrics.imageRadius)
                .frame(width: metrics.imageTile.width, height: metrics.imageTile.height)
                .help(Text(verbatim: attachment.fileName))
        case .pdf, .text:
            HStack(spacing: 5) {
                Image(systemName: AttachmentText.glyph(attachment))
                    .font(.system(size: 12.5))
                    .accessibilityHidden(true)
                Text(verbatim: attachment.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = AttachmentText.detail(attachment) {
                    Text(verbatim: detail)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.system(size: metrics.fileTileText))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .padding(.trailing, 9)
            .frame(height: metrics.fileTileHeight)
            .frame(maxWidth: 220, alignment: .leading)
            .background(Color.contentBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Drop

extension View {
    /// Files dropped on the panel go to the composer; only files it can read light the panel
    /// (anything else gets no ring and no badge, and the window's import keeps it).
    func agentFileDrop(model: AgentPanelModel, isTargeted: Binding<Bool>) -> some View {
        modifier(AgentFileDrop(model: model, isTargeted: isTargeted))
    }
}

private struct AgentFileDrop: ViewModifier {
    let model: AgentPanelModel
    @Binding var isTargeted: Bool
    @Environment(\.studyServices) private var services

    func body(content: Content) -> some View {
        #if os(macOS)
        if let services {
            content.onDrop(of: [.fileURL, .png, .tiff, .jpeg], delegate: AgentDropDelegate(model: model, blobs: services.blobs, isTargeted: $isTargeted))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(macOS)
/// Reads the drag pasteboard directly (file URLs synchronously, so a drop of a ZIP is refused
/// before it lands; images without a file).
@MainActor
private struct AgentDropDelegate: DropDelegate {
    let model: AgentPanelModel
    let blobs: BlobStore
    @Binding var isTargeted: Bool

    private var pasteboard: NSPasteboard { NSPasteboard(name: .drag) }

    func validateDrop(info: DropInfo) -> Bool {
        model.canAttach && (!AgentPasteboard.acceptedURLs(pasteboard).isEmpty || AgentPasteboard.imageData(pasteboard) != nil)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .copy) : DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return AgentPasteboard.attach(from: pasteboard, model: model, blobs: blobs)
    }
}

/// Files and images on a pasteboard (a drag's, or the general one for ⌘V).
@MainActor
enum AgentPasteboard {
    /// File URLs the accept rule takes.
    static func acceptedURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { AgentAttachment.kind(forFileName: $0.lastPathComponent) != nil }
    }

    /// Image bytes without a file (a screenshot copied to the clipboard): PNG, else TIFF.
    static func imageData(_ pasteboard: NSPasteboard) -> (data: Data, type: UTType)? {
        if let png = pasteboard.data(forType: .png) { return (png, .png) }
        if let tiff = pasteboard.data(forType: .tiff) { return (tiff, .tiff) }
        return nil
    }

    /// Attaches the pasteboard's accepted files, else its image; false when it holds neither.
    static func attach(from pasteboard: NSPasteboard, model: AgentPanelModel, blobs: BlobStore) -> Bool {
        let urls = acceptedURLs(pasteboard)
        if !urls.isEmpty {
            model.attach(urls: urls, blobs: blobs)
            return true
        }
        let hasFiles = !(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).isEmpty
        guard !hasFiles, let image = imageData(pasteboard) else { return false }
        model.attach(data: image.data, type: image.type, fileName: String(localized: "Screenshot") + ".png", blobs: blobs)
        return true
    }
}

/// ⌘V in the composer: a copied file or screenshot becomes a tile; text pastes as text. A local
/// key monitor while the composer has focus (the field editor would paste a file's name).
struct AgentPasteMonitor: ViewModifier {
    let isActive: Bool
    let model: AgentPanelModel
    @Environment(\.studyServices) private var services
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                if active { install() } else { remove() }
            }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil, let services else { return }
        let model = model
        let blobs = services.blobs
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }
            let handled = MainActor.assumeIsolated {
                AgentPasteboard.attach(from: .general, model: model, blobs: blobs)
            }
            return handled ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
