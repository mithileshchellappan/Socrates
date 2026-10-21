import DocumentsUI
import ImageIO
import StudyCore
import StudyUI
import SwiftUI

// The shelf's tiles and rows (docs/plan-materials.md §2.2, mockups 36 and 39).

/// A book: the cover 112 wide at page 1's aspect (3:4 until known) on white paper with a hairline
/// and the slide paper's soft shadow, radius 3, white in both appearances; under it the title (13
/// semibold, 2 lines), the authors (12 secondary, 1 line) and "640 pages · 14 chapters" (11.5
/// tertiary, digits in SF Mono). Being read: a skeleton cover and redacted lines, the file name
/// as title. Failed: the triangle after the title, the reason under it. Wanted: a quiet cover
/// with `book`, the title and authors, nothing else (a drop target for its PDF).
struct BookTile: View {
    let material: CourseMaterial
    let document: StudyDocument?
    let chapters: Int
    let fill: (CourseMaterial.ID, URL) -> Void

    static let coverWidth: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: material.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(material.state == .pending ? .middle : .tail)
                        .fixedSize(horizontal: false, vertical: true)
                    if material.state == .failed {
                        FailureMark(reason: material.error)
                    }
                }
                switch material.state {
                case .pending:
                    SkeletonLine(width: 70)
                        .padding(.top, 5)
                case .failed:
                    if let error = material.error {
                        Text(verbatim: error)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                case .wanted, .ready:
                    if !material.byline.isEmpty {
                        Text(verbatim: material.byline)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if material.state == .ready, material.pageCount > 0 {
                        sizeLine
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                }
            }
            .padding(.top, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    /// "640 pages · 14 chapters".
    private var sizeLine: Text {
        let pages = MaterialsText.count(material.pageCount, one: String(localized: "page"), many: String(localized: "pages"))
        let line = chapters > 0
            ? Text("\(pages) · \(MaterialsText.count(chapters, one: String(localized: "chapter"), many: String(localized: "chapters")))")
            : pages
        return line
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var cover: some View {
        switch material.state {
        case .pending:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(QuietFill())
                .frame(width: Self.coverWidth, height: Self.coverWidth * 4 / 3)
        case .wanted:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(QuietFill())
                .frame(width: Self.coverWidth, height: Self.coverWidth * 4 / 3)
                .overlay {
                    Image(systemName: "book")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                }
        case .ready, .failed:
            MaterialCover(document: document, width: Self.coverWidth)
        }
    }
}

/// A file's cover: `MaterialCovers` (cached, drawn off the main actor when missing), white paper
/// with a hairline and a soft shadow; 3:4 on white until it is there.
struct MaterialCover: View {
    let document: StudyDocument?
    let width: CGFloat
    var radius: CGFloat = 3
    @Environment(\.studyServices) private var services
    @State private var image: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: CGFloat(image.width) / width)
                    .resizable()
                    .frame(width: width, height: width * CGFloat(image.height) / CGFloat(max(1, image.width)))
            } else {
                Color.white.frame(width: width, height: width * 4 / 3)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        .accessibilityHidden(true)
        .task(id: document?.blobSHA256) { await load() }
    }

    private func load() async {
        guard let services, let document, let blob = document.blob, !document.blobSHA256.isEmpty else { return }
        let file = services.blobs.url(for: blob)
        let paths = services.paths
        let sha = document.blobSHA256
        image = await MaterialCoverLoader.image(pdfAt: file, sha256: sha, paths: paths)
    }
}

/// Covers off the main actor (the cache, else drawn from the PDF).
enum MaterialCoverLoader {
    @concurrent
    static func image(pdfAt file: URL, sha256: String, paths: AppPaths) async -> CGImage? {
        guard let url = MaterialCovers.cover(pdfAt: file, sha256: sha256, paths: paths) else { return nil }
        return pngImage(at: url)
    }

    @concurrent
    static func favicon(hash: String, paths: AppPaths) async -> CGImage? {
        pngImage(at: MaterialCovers.faviconURL(hash: hash, paths: paths))
    }

    private static func pngImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// A paper, a reference or a link (min 44, hairlines from the text's start, the quiet fill on
/// hover): the glyph (16) | the title (13 medium, one line) over its second line (12 secondary) |
/// the trailing fact (11.5 tertiary): "24 pages", the language ("Go") or the host.
struct MaterialRow: View {
    let material: CourseMaterial
    let document: StudyDocument?
    let showsHairline: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            glyph
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if material.state == .failed {
                        FailureMark(reason: material.error)
                    }
                }
                secondLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                trailing
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(QuietFill())
            }
        }
        .overlay(alignment: .top) {
            if showsHairline, !isHovered {
                Hairline().padding(.leading, 34).padding(.trailing, 8)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }

    /// A link being fetched shows its host; a repository "owner/repo".
    private var title: String {
        if material.kind.isLink, material.state == .pending {
            return MaterialText.host(material) ?? material.title
        }
        return material.title
    }

    @ViewBuilder
    private var glyph: some View {
        if material.kind == .website, let hash = material.facts.faviconHash {
            Favicon(hash: hash)
        } else {
            Image(systemName: MaterialText.glyph(material.kind))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var secondLine: some View {
        switch material.state {
        case .pending:
            SkeletonLine(width: material.kind.isLink ? 330 : 160)
                .padding(.vertical, 3)
        case .failed:
            if let error = material.error {
                Text(verbatim: error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .ready, .wanted:
            if material.kind.isLink {
                linkLine
            } else {
                let byline = MaterialsText.byline(material)
                if !byline.isEmpty {
                    Text(verbatim: byline)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The page's own description (its words: no sparkle, like a mail snippet); without one the
    /// card's summary, grey with one sparkle. Never rendered as Markdown or HTML.
    @ViewBuilder
    private var linkLine: some View {
        let summary = material.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if material.summarySource == .ai {
                    AIMark()
                        .font(.system(size: 10))
                }
                Text(verbatim: summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var trailing: Text? {
        switch material.state {
        case .pending, .failed: return nil
        default: break
        }
        switch material.kind {
        case .repository:
            return material.facts.language.map { Text(verbatim: $0) }
        case .website:
            return material.url.flatMap(FurtherReadingRow.domain).map { Text(verbatim: $0) }
        default:
            guard material.pageCount > 0 else { return nil }
            return MaterialsText.count(material.pageCount, one: String(localized: "page"), many: String(localized: "pages"))
        }
    }
}

/// A website's favicon (16, cached by the link fetcher), else `globe`.
struct Favicon: View {
    let hash: String
    @Environment(\.studyServices) private var services
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: hash) {
            guard let services else { return }
            image = await MaterialCoverLoader.favicon(hash: hash, paths: services.paths)
        }
    }
}

/// After a failed title: a secondary triangle, the reason as its help.
struct FailureMark: View {
    let reason: String?

    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help(Text(verbatim: reason ?? ""))
            .accessibilityLabel(Text(verbatim: reason ?? String(localized: "Failed")))
    }
}

/// A redacted line on the quiet fill (no shimmer, DESIGN 6.6).
struct SkeletonLine: View {
    let width: CGFloat

    var body: some View {
        Capsule()
            .fill(QuietFill())
            .frame(width: width, height: 9)
            .frame(maxWidth: width, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A wanted book's cover takes its PDF: the accent ring while a PDF hovers over it.
struct WantedDrop: ViewModifier {
    let material: CourseMaterial
    let isEnabled: Bool
    let fill: (CourseMaterial.ID, URL) -> Void
    @State private var isTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if material.state == .wanted, isEnabled {
            content
                .overlay(alignment: .topLeading) {
                    if isTargeted {
                        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
                        shape
                            .fill(Color.accentSoft(colorScheme))
                            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1.5))
                            .frame(width: BookTile.coverWidth, height: BookTile.coverWidth * 4 / 3)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let pdf = urls.first(where: MaterialDrop.isPDF) else { return false }
                    fill(material.id, pdf)
                    return true
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}
