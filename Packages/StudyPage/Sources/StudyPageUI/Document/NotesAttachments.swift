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
    /// The student's note a run shows (its id string): Edit in Review.
    static let notesStudentNote = NSAttributedString.Key("Socrates.notesStudentNote")
}

/// The roles of the document's paragraphs.
enum NotesRole: String {
    case heading
    /// Claude's text: prose, lists, callouts, figures.
    case body
    /// The student's note, drawn as Notes draws it.
    case studentNote
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

/// Told when an attachment's view changed its height (a slide loaded, Answers opened).
@MainActor
protocol NotesSizeObserver: AnyObject {
    func attachmentChangedSize()
}

/// A block of its own (a figure, a kept answer, the writing line): SwiftUI hosted as wide as the
/// line, as tall as its content. The first layout uses a measured height; the view then reports
/// its own, and the document lays out again when that differs.
@MainActor
final class HostedBlockAttachment: NotesAttachment {
    private let content: AnyView
    private let text: String
    /// Room above and below the block inside its line.
    private let margin: CGFloat
    private var estimate: CGFloat
    private var estimatedWidth: CGFloat = -1
    private var reported: CGFloat?

    init(_ content: some View, estimate: CGFloat, margin: CGFloat = 4, plainText: String = "") {
        self.content = AnyView(content)
        self.estimate = estimate
        self.margin = margin
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
        let width = max(1, floor(lineWidth) - 1)
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
#endif
