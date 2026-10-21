import StudyCore
import SwiftUI

// mt (docs/plan-materials.md §2): what the screens share about course materials: the library the
// app injects, the book chip, and where a further-reading row or a reading opens a material.

extension EnvironmentValues {
    /// The material library (Documents' `MaterialLibrary`, the Mac): drops, ⌘V, Import…, Delete
    /// with Undo, Show As, Read Again. Nil (the iPhone, previews): the Materials screen is
    /// read-only.
    @Entry public var materialLibrary: (any MaterialLibraryActions)?
}

/// A place in a course material: the reader at a PDF page (nil: where the student was).
public struct MaterialLink: Hashable, Sendable {
    public var id: CourseMaterial.ID
    /// 1-based PDF page.
    public var page: Int?

    public init(id: CourseMaterial.ID, page: Int?) {
        self.id = id
        self.page = page
    }

    /// The first `.material` citation of a further-reading row or a reading (the book row the
    /// study pass's `cover` unit wrote), nil for a web row.
    public static func first(in citations: [SourceRef]) -> MaterialLink? {
        guard let ref = citations.first(where: { $0.kind == .material && $0.materialID != nil }), let id = ref.materialID else {
            return nil
        }
        return MaterialLink(id: id, page: ref.pageNumber)
    }

    public var destination: StudyDestination { .material(id, page: page) }

    /// "socrates://material/<uuid>?page=231": a material's place as a link (a reading's Read
    /// block; the window's `OpenURLAction` routes it in process).
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "socrates"
        components.host = "material"
        components.path = "/" + id.uuidString.lowercased()
        if let page { components.queryItems = [URLQueryItem(name: "page", value: String(page))] }
        return components.url
    }

    /// The place a `socrates://material/…` link names; nil for any other URL.
    public init?(url: URL) {
        guard url.scheme == "socrates", url.host() == "material",
              let id = UUID(uuidString: url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        else { return nil }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init)
        self.init(id: id, page: page)
    }
}

/// A book chip: `book` + "§6.2 · p. 214" / "Ch. 6" (SF Mono 10.5, secondary on the quiet fill,
/// web's chip shape with the book's glyph); its help the book's title; opens the reader.
public struct BookChip: View {
    private let label: String
    private let help: String
    private let action: () -> Void

    public init(_ label: String, help: String, action: @escaping () -> Void) {
        self.label = label
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "book")
                    .font(.system(size: 9))
                Text(verbatim: label)
                    .monospacedDigit()
                    .font(.chip)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(.secondary)
            .background(QuietFill(), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: help))
        .accessibilityLabel(Text(verbatim: help.isEmpty ? label : "\(help), \(label)"))
    }
}

public enum MaterialText {
    /// "Ch. 6" or "Ch. 6, 7" (the chapters a lecture covers, in order; at most three named).
    public static func chapters(_ numbers: [String]) -> String {
        let shown = numbers.prefix(3)
        guard !shown.isEmpty else { return "" }
        return "Ch.\u{00A0}" + shown.joined(separator: ", ")
    }

    /// "§6.2 · p. 214" (the section holding the page, the printed page), "p. 214" without a
    /// section; non-breaking, so a chip never breaks.
    public static func citeLabel(section: MaterialSection?, material: CourseMaterial, pdfPage: Int?) -> String {
        let nbsp = "\u{00A0}"
        let page = pdfPage.map { material.pageLabel(pdfPage: $0).replacingOccurrences(of: " ", with: nbsp) }
        switch (section, page) {
        case (let section?, let page?) where !section.number.isEmpty:
            return section.citeLabel.replacingOccurrences(of: " ", with: nbsp) + "\(nbsp)·\(nbsp)" + page
        case (_, let page?):
            return page
        case (let section?, nil):
            return section.citeLabel.replacingOccurrences(of: " ", with: nbsp)
        case (nil, nil):
            return host(material) ?? material.title
        }
    }

    /// A link's host without "www." ("dc-course.example.org"), or a repository's "owner/repo".
    public static func host(_ material: CourseMaterial) -> String? {
        if material.kind == .repository, let owner = material.facts.owner, let repo = material.facts.repo {
            return "\(owner)/\(repo)"
        }
        guard let url = material.url else { return nil }
        return FurtherReadingRow.domain(url)
    }

    /// "640 pages" / "1 page".
    public static func pages(_ count: Int) -> String {
        count == 1 ? String(localized: "1 page") : String(localized: "\(count) pages")
    }

    /// "14 chapters" / "1 chapter".
    public static func chapterCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 chapter") : String(localized: "\(count) chapters")
    }

    /// A material's glyph: `book` a book, `doc.text` a paper, `doc` a reference,
    /// `chevron.left.forwardslash.chevron.right` a repository, `globe` a website.
    public static func glyph(_ kind: MaterialKind) -> String {
        switch kind {
        case .book: "book"
        case .paper: "doc.text"
        case .repository: "chevron.left.forwardslash.chevron.right"
        case .website: "globe"
        default: "doc"
        }
    }
}
