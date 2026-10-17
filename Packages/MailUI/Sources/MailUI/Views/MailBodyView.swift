import QuickLook
import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

/// The rendered body: paragraphs, headings, lists, preformatted text; quoted earlier mail
/// collapsed behind one control. Links open only when clicked.
struct MailBodyView: View {
    let mailBody: MailBody
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(mailBody.sections) { section in
                switch section {
                case .block(let block):
                    MailBlockView(block: block)
                case .quoted(let blocks):
                    if expanded.contains(section.id) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(blocks) { MailBlockView(block: $0) }
                        }
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.separator).frame(width: 2)
                        }
                    } else {
                        Button {
                            expanded.insert(section.id)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 28, height: 14)
                                .background(.quaternary, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Show Quoted Text"))
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailBlockView: View {
    let block: MailBlock

    var body: some View {
        Group {
            switch block.kind {
            case .paragraph:
                Text(block.text)
            case .heading(let level):
                Text(block.text)
                    .font(.system(size: level <= 1 ? 17 : level == 2 ? 15 : 13, weight: .semibold))
            case .listItem(let marker):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: marker)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 12, alignment: .trailing)
                    Text(block.text)
                }
            case .preformatted:
                Text(block.text)
                    .font(.system(size: 12, design: .monospaced))
            case .rule:
                Divider()
                    .padding(.vertical, 4)
            }
        }
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, CGFloat(block.indent) * 18)
    }
}

/// One attachment: glyph, name, size. Click opens Quick Look; drag hands the file out (decoded on
/// first use through `MailActions.openAttachment`).
struct AttachmentChip: View {
    let attachment: MailAttachment

    @Environment(\.mailActions) private var actions
    @State private var previewURL: URL?
    @State private var failure: String?
    @State private var isOpening = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: Self.glyph(for: attachment))
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.fileName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        if failure != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                        Text(MailText.byteCount(attachment.size))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(failure ?? attachment.fileName)
        .quickLookPreview($previewURL)
        .onDrag { itemProvider() }
    }

    private func open() {
        guard !isOpening else { return }
        isOpening = true
        let actions = actions
        let id = attachment.id
        Task {
            do {
                previewURL = try await actions.openAttachment(id)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            isOpening = false
        }
    }

    /// A file promise: the file is decoded only when the drop asks for it.
    private func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = attachment.fileName
        let type = Self.contentType(for: attachment)
        let actions = actions
        let id = attachment.id
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task {
                do {
                    completion(try await actions.openAttachment(id), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    static func contentType(for attachment: MailAttachment) -> UTType {
        UTType(mimeType: attachment.mimeType)
            ?? UTType(filenameExtension: (attachment.fileName as NSString).pathExtension)
            ?? .data
    }

    static func glyph(for attachment: MailAttachment) -> String {
        let type = contentType(for: attachment)
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}
