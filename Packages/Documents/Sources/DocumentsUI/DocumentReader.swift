import StudyCore
import StudyUI
import SwiftUI

/// The reader (docs/plan-docs.md §6 "Reader"), at most 680 wide and centred with Notes' margins:
/// the title (22 bold: a name, primary), the facts line ("Handbook · PDF · 6 pages · Added Mon
/// 19 Oct", 12 secondary, digits in SF Mono), the related courses (dot + short name; absent when
/// none), the file as one tile (a click opens Quick Look), then the AI blocks Summary, Key facts and
/// Dates, each a section label over grey text with ONE sparkle at its first line ("p. 12" in SF
/// Mono; a block without content is absent). Pending: the Summary as a 3-line skeleton. Failed: one
/// secondary line with the triangle and the reason, and Read Again.
struct DocumentReader: View {
    let document: StudyDocument
    let courses: [Course]
    /// The page a search hit or a chip named: its key facts and dates are marked.
    let page: Int?
    let now: Date
    let isEditable: Bool
    let quickLook: () -> Void
    let retry: () -> Void

    /// Notes' document measures (DESIGN 3.3): text at most 680 wide, at least 52 from each side.
    static let maxWidth: CGFloat = 680
    static let sideMargin: CGFloat = 52
    /// The sparkle's column before a block's first line (the other rows keep its indent).
    static let sparkleWidth: CGFloat = 13

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                DocumentFileTile(document: document, action: quickLook)
                    .padding(.top, 18)
                blocks
                    .padding(.top, 8)
            }
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .padding(.horizontal, Self.sideMargin)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: document.title)
                .font(.title.bold())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            DocumentText.monoDigits(factsLine, size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !relatedCourses.isEmpty {
                HStack(spacing: 12) {
                    ForEach(relatedCourses) { course in
                        HStack(spacing: 5) {
                            CourseDot(course: course, size: 8)
                            Text(verbatim: course.shortName.isEmpty ? course.name : course.shortName)
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "Handbook · PDF · 6 pages · Added Mon 19 Oct".
    private var factsLine: String {
        [DocumentText.kind(document.kind), DocumentText.fileType(document), DocumentText.pages(document), DocumentText.added(document.addedAt, now: now)]
            .compactMap(\.self)
            .joined(separator: " · ")
    }

    /// The courses it concerns, in the sidebar's order (unknown ids left out).
    private var relatedCourses: [Course] {
        courses.filter { document.courseIDs.contains($0.id) }
    }

    // MARK: Blocks

    @ViewBuilder
    private var blocks: some View {
        switch DocumentState(document) {
        case .failed(let reason):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label {
                    Text(verbatim: reason)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                if isEditable {
                    Button("Read Again", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.top, 18)
        case .pending:
            block("Summary") {
                skeleton
            }
        case .done:
            if !document.summary.isEmpty {
                block("Summary") {
                    sparkled {
                        Text(verbatim: document.summary)
                            .font(.system(size: 13))
                            .lineSpacing(2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !document.keyFacts.isEmpty {
                block("Key facts") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(document.keyFacts.enumerated()), id: \.offset) { index, fact in
                            DocumentBlockRow(sparkle: index == 0, page: fact.page, isMarked: isMarked(fact.page), open: quickLook) {
                                Text(verbatim: fact.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if !document.dates.isEmpty {
                block("Dates") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(document.dates.enumerated()), id: \.offset) { index, date in
                            DocumentBlockRow(sparkle: index == 0, page: date.page, isMarked: isMarked(date.page), open: quickLook) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(verbatim: DocumentText.day(date, now: now))
                                        .font(.mono(12))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                    Text(verbatim: date.what)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func isMarked(_ factPage: Int?) -> Bool {
        guard let page, let factPage else { return false }
        return page == factPage
    }

    /// A block: its section label (subheadline semibold secondary) over its content.
    private func block(_ label: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, 18)
    }

    /// The block's one sparkle before its first line.
    private func sparkled(@ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            AIMark()
                .font(.system(size: 12))
                .frame(width: DocumentReader.sparkleWidth, alignment: .leading)
            content()
        }
    }

    /// Three lines at the summary's size, redacted, no shimmer (DESIGN 6.6).
    private var skeleton: some View {
        sparkled {
            Text(verbatim: "The summary of this document is being written now. It says what the document is, who wrote it and for whom, and what it will be looked up for later, in one to three sentences. Key facts and dates follow it once the whole document has been read.")
                .font(.system(size: 13))
                .lineSpacing(2)
                .lineLimit(3, reservesSpace: true)
                .foregroundStyle(.secondary)
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
        }
    }
}

/// A key fact or date: [the sparkle on the first row only | the content | "p. 12" trailing in
/// tertiary SF Mono]; a click opens the file in Quick Look. A row on the page a hit or chip named
/// sits on the quiet fill.
struct DocumentBlockRow<Content: View>: View {
    let sparkle: Bool
    let page: Int?
    let isMarked: Bool
    let open: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Group {
                    if sparkle {
                        AIMark()
                            .font(.system(size: 12))
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: DocumentReader.sparkleWidth, alignment: .leading)
                content
                Spacer(minLength: 12)
                if let page {
                    DocumentText.monoDigits(DocumentText.page(page), size: 11)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background {
                if isMarked {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(QuietFill())
                }
            }
            .padding(.horizontal, -6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// The original file as one tile: the first page's thumbnail (64 high, radius 6 with a hairline),
/// the file name (13 medium) over "PDF · 2.4 MB" (12 secondary). A click opens Quick Look.
struct DocumentFileTile: View {
    let document: StudyDocument
    let action: () -> Void

    @Environment(\.studyServices) private var services
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: CGImage?

    static let thumbnailHeight: CGFloat = 64

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                preview
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: document.fileName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    DocumentText.monoDigits("\(DocumentText.fileType(document)) · \(DocumentText.size(document))", size: 12)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.trailing, 6)
            }
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text("Quick Look"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .task(id: document.blobSHA256) {
            thumbnail = nil
            guard let services, let blob = document.blob else { return }
            let url = services.blobs.url(for: blob)
            let size = CGSize(width: Self.thumbnailHeight * 1.5, height: Self.thumbnailHeight)
            thumbnail = await DocumentFiles.thumbnail(at: url, size: size, scale: max(1, displayScale))
        }
    }

    @ViewBuilder
    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if let thumbnail {
            let aspect = CGFloat(thumbnail.width) / CGFloat(max(1, thumbnail.height))
            Image(decorative: thumbnail, scale: max(1, displayScale))
                .resizable()
                .aspectRatio(aspect, contentMode: .fit)
                .frame(height: Self.thumbnailHeight)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
                .accessibilityHidden(true)
        } else {
            // The page's place, the same size, until (or without) a thumbnail: no jump.
            shape
                .fill(QuietFill())
                .frame(width: Self.thumbnailHeight * 0.75, height: Self.thumbnailHeight)
                .overlay {
                    Image(systemName: DocumentText.fileGlyph(document))
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                }
                .overlay(shape.strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }
}
