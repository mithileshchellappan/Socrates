#if os(macOS)
import AppKit
import NotesUI
import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

// What the notes document shows besides text: figures, chips, kept answers and the writing state
// are TextKit 2 attachments (NotesUI's machinery), one character each, so a selection runs across
// them and Copy takes their words.

extension NSAttributedString.Key {
    /// The part a character belongs to (`LectureNotesSection.key`, or "overview").
    static let notesSection = NSAttributedString.Key("Socrates.notesSection")
    /// What a paragraph is (`NotesRole`).
    static let notesRole = NSAttributedString.Key("Socrates.notesRole")
    /// A section heading's key (the fold chevron hangs before it).
    static let notesHeading = NSAttributedString.Key("Socrates.notesHeading")
    /// A callout's kind (`MarkdownBlock.CalloutKind.rawValue`, or "quote" for a plain quote).
    static let notesCallout = NSAttributedString.Key("Socrates.notesCallout")
    /// A paragraph's style before the page's prose inset (nl, docs/plan-notes-layout.md §3): the
    /// coordinator indents every paragraph that carries one by the inset on both sides. Breakouts
    /// (code, tables, diagrams, charts, slides) carry none and span the text view.
    static let notesBaseStyle = NSAttributedString.Key("Socrates.notesBaseStyle")
    /// The prose inset a paragraph is indented by (a callout's fragment draws its fill there).
    static let notesInset = NSAttributedString.Key("Socrates.notesInset")
}

/// The roles of the document's paragraphs.
enum NotesRole: String {
    case heading
    /// Claude's text: prose, lists, callouts, figures.
    case body
    /// A kept answer under its paragraph.
    case kept
    /// Skeleton, the writing line, a failure: not part of the text.
    case chrome
}

/// A character of the notes that shows a view or an image.
@MainActor
class NotesAttachment: TextAttachmentContent {
    /// Its words in a copy ("S13", the formula, the code).
    var plainText: String { "" }
    weak var host: NotesSizeObserver?

    func makeView() -> NSView? { nil }

    func bounds(lineWidth: CGFloat, view: NSView?) -> CGRect { .zero }

    func attachment() -> NoteTextAttachment {
        NoteTextAttachment(self)
    }
}

/// The page's prose inset (nl, §3), shared by the document's attachments: TextKit proposes the
/// text container's whole width to an attachment whatever its paragraph's indents, so one at the
/// measure (a kept answer, a professor's quote, the writing line) takes `inset` off each side.
@MainActor
final class NotesLayoutBox {
    var inset: CGFloat = 0
}

/// Told when an attachment's view changed its height (a slide loaded, Answers opened).
@MainActor
protocol NotesSizeObserver: AnyObject {
    func attachmentChangedSize()
}

/// A block of its own (a figure, a kept answer, the writing line): SwiftUI hosted as wide as the
/// line, as tall as its content. The first layout uses a measured height; the view then reports
/// its own, and the document lays out again when that differs. With a `measure` box it sits at
/// the measure (its paragraph is indented by the inset): that much narrower on each side.
@MainActor
final class HostedBlockAttachment: NotesAttachment {
    private let content: AnyView
    private let text: String
    /// Room above and below the block inside its line.
    private let margin: CGFloat
    private let measure: NotesLayoutBox?
    private var estimate: CGFloat
    private var estimatedWidth: CGFloat = -1
    private var reported: CGFloat?

    init(_ content: some View, estimate: CGFloat, margin: CGFloat = 4, plainText: String = "", measure: NotesLayoutBox? = nil) {
        self.content = AnyView(content)
        self.estimate = estimate
        self.margin = margin
        self.measure = measure
        text = plainText
    }

    override var plainText: String { text }

    override func makeView() -> NSView? {
        let view = NoteAttachmentHostingView(rootView: AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    self?.report(height)
                }
                .padding(.vertical, margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        ))
        return view
    }

    override func bounds(lineWidth: CGFloat, view: NSView?) -> CGRect {
        let width = max(1, floor(lineWidth - 2 * (measure?.inset ?? 0)) - 1)
        if reported == nil, abs(estimatedWidth - width) > 0.5 {
            estimatedWidth = width
            let controller = NSHostingController(rootView: content.fixedSize(horizontal: false, vertical: true))
            let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            if size.height.isFinite, size.height > 0 { estimate = size.height }
        }
        return CGRect(x: 0, y: -4, width: width, height: ceil((reported ?? estimate) + 2 * margin))
    }

    private func report(_ height: CGFloat) {
        guard height > 0 else { return }
        if let reported, abs(reported - height) < 0.5 { return }
        let changed = abs((reported ?? estimate) - height) >= 0.5
        reported = height
        if changed { host?.attachmentChangedSize() }
    }
}

/// An inline view (a chip): hosted at its own size on the baseline.
@MainActor
final class InlineViewAttachment: NotesAttachment {
    private let content: AnyView
    private let text: String
    private let baseline: CGFloat
    private var size: CGSize?

    init(_ content: some View, plainText: String, baseline: CGFloat = -3.5) {
        self.content = AnyView(content.fixedSize())
        text = plainText
        self.baseline = baseline
    }

    override var plainText: String { text }

    override func makeView() -> NSView? {
        let view = NoteAttachmentHostingView(rootView: content)
        size = view.fittingSize
        return view
    }

    override func bounds(lineWidth: CGFloat, view: NSView?) -> CGRect {
        if size == nil {
            size = NSHostingView(rootView: content).fittingSize
        }
        let size = size ?? CGSize(width: 36, height: 16)
        return CGRect(x: 0, y: baseline, width: ceil(size.width) + 1, height: ceil(size.height))
    }
}

/// An inline image (a formula, the sparkle, the star) already in its colour for the document's
/// appearance (the document is drawn again when the appearance changes): no view, so a long text
/// full of formulas stays light.
@MainActor
enum ImageAttachment {
    static func string(_ image: NSImage, baseline: CGFloat, plainText: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let attachment = PlainTextAttachment(plainText: plainText)
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: baseline, width: image.size.width, height: image.size.height)
        var attributes = attributes
        attributes[.attachment] = attachment
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }

    /// An SF Symbol at `size` points in `color`.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}

/// An image attachment that knows its words for a copy.
final class PlainTextAttachment: NSTextAttachment {
    let plainText: String

    init(plainText: String) {
        self.plainText = plainText
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { nil }
}

/// The page's prose inset applied to paragraph styles (nl, §3): every paragraph with a base style
/// (`.notesBaseStyle`) is indented by `inset` on both sides, its list markers' and quote bars'
/// tab stops moved with it; a section heading's chip tab sits at the measure's end. Attributes
/// only: no text changes, so nothing is parsed or drawn again.
@MainActor
enum NotesIndent {
    static func apply(to text: NSMutableAttributedString, in range: NSRange? = nil, inset: CGFloat, width: CGFloat) {
        let range = range ?? NSRange(location: 0, length: text.length)
        guard range.length > 0 else { return }
        text.enumerateAttribute(.notesBaseStyle, in: range) { value, sub, _ in
            guard let base = value as? NSParagraphStyle else { return }
            let isHeading = text.attribute(.notesHeading, at: sub.location, effectiveRange: nil) != nil
            text.addAttribute(.paragraphStyle, value: style(base, inset: inset, width: width, isHeading: isHeading), range: sub)
            text.addAttribute(.notesInset, value: inset, range: sub)
        }
    }

    static func style(_ base: NSParagraphStyle, inset: CGFloat, width: CGFloat, isHeading: Bool) -> NSParagraphStyle {
        guard let style = base.mutableCopy() as? NSMutableParagraphStyle else { return base }
        style.headIndent = base.headIndent + inset
        style.firstLineHeadIndent = base.firstLineHeadIndent + inset
        // A tail indent of 0 or less counts from the container's trailing edge.
        style.tailIndent = base.tailIndent <= 0 ? base.tailIndent - inset : base.tailIndent
        if isHeading {
            style.tabStops = [NSTextTab(textAlignment: .right, location: max(40, width - inset), options: [:])]
        } else if !base.tabStops.isEmpty {
            style.tabStops = base.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + inset, options: $0.options) }
        }
        return style
    }
}
#endif
