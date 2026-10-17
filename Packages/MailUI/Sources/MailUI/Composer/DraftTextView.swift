import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The draft's text editor: plain text whose words are coloured by who wrote them. The agent's
/// unchanged words are secondary (AI style), the student's primary; colours are recomputed on
/// every keystroke from the word diff without touching the text or the selection, and newly typed
/// text is always primary. Its own platform text view (the one AppKit/UIKit view of MailUI):
/// SwiftUI's `TextEditor` cannot colour ranges of plain text it edits.
///
/// The first line is indented for the sparkle the composer draws over it while there are agent
/// words (`leadingIndent`).
struct DraftTextView {
    var text: String
    /// What the agent wrote (nil: the student wrote it all).
    var generated: String?
    var isEditable: Bool
    /// Room before the first line (the sparkle).
    var leadingIndent: CGFloat
    /// Take keyboard focus once (Reply, New Message).
    var wantsFocus: Bool
    var onEdit: (String) -> Void
    var onFocusChange: (Bool) -> Void

    static let fontSize: CGFloat = 13
    static let lineSpacing: CGFloat = 3
}

#if canImport(AppKit)
extension DraftTextView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> DraftNSTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = DraftNSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20), textContainer: container)
        view.isRichText = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.font = Self.font
        view.delegate = context.coordinator
        let coordinator = context.coordinator
        view.onFocusChange = { [weak coordinator] focused in coordinator?.parent.onFocusChange(focused) }
        view.string = text
        context.coordinator.recolor(view)
        return view
    }

    func updateNSView(_ view: DraftNSTextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = isEditable
        view.isSelectable = true
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        context.coordinator.recolor(view)
        if wantsFocus, let window = view.window, window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: DraftNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = view.textContainer, let layout = view.layoutManager else { return nil }
        // Measure at the proposed width, then give the container back the view's own width:
        // SwiftUI probes with other widths, and when the frame it then sets is unchanged,
        // `widthTracksTextView` never resizes the container (text one character wide).
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        if view.frame.width > 0, view.frame.width != width {
            container.containerSize = NSSize(width: view.frame.width, height: CGFloat.greatestFiniteMagnitude)
        }
        let minimum = ceil(Self.font.ascender - Self.font.descender + Self.font.leading) + Self.lineSpacing
        return CGSize(width: width, height: max(ceil(used), minimum * 3))
    }

    static var font: NSFont { NSFont.systemFont(ofSize: fontSize) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DraftTextView

        init(parent: DraftTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            recolor(view)
            parent.onEdit(view.string)
        }

        /// Colours by provenance and sets the first line's indent; text and selection unchanged.
        func recolor(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let string = storage.string
            let full = NSRange(location: 0, length: storage.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = DraftTextView.lineSpacing
            let first = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            first.firstLineHeadIndent = parent.leadingIndent
            storage.beginEditing()
            storage.addAttribute(.font, value: DraftTextView.font, range: full)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: full)
            for range in ProvenanceDiff.agentNSRanges(generated: parent.generated, body: string) {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            }
            if storage.length > 0 {
                let firstParagraph = (string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                storage.addAttribute(.paragraphStyle, value: first, range: firstParagraph)
            }
            storage.endEditing()
            view.typingAttributes = [
                .font: DraftTextView.font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: storage.length == 0 ? first : paragraph,
            ]
        }
    }
}

/// Reports focus, and pastes plain text only.
final class DraftNSTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

#elseif canImport(UIKit)
extension DraftTextView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = Self.font
        view.delegate = context.coordinator
        view.text = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.recolor(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = isEditable
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
        context.coordinator.recolor(view)
        if wantsFocus, !view.isFirstResponder, view.window != nil {
            view.becomeFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = view.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: max(size.height, Self.font.lineHeight * 3))
    }

    static var font: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DraftTextView

        init(parent: DraftTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            recolor(textView)
            parent.onEdit(textView.text)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        func recolor(_ view: UITextView) {
            let storage = view.textStorage
            let string = storage.string
            let full = NSRange(location: 0, length: storage.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = DraftTextView.lineSpacing
            let first = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            first.firstLineHeadIndent = parent.leadingIndent
            let selection = view.selectedRange
            storage.beginEditing()
            storage.addAttribute(.font, value: DraftTextView.font, range: full)
            storage.addAttribute(.foregroundColor, value: UIColor.label, range: full)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: full)
            for range in ProvenanceDiff.agentNSRanges(generated: parent.generated, body: string) {
                storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
            }
            if storage.length > 0 {
                let firstParagraph = (string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                storage.addAttribute(.paragraphStyle, value: first, range: firstParagraph)
            }
            storage.endEditing()
            view.selectedRange = selection
            view.typingAttributes = [
                .font: DraftTextView.font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: storage.length == 0 ? first : paragraph,
            ]
        }
    }
}
#endif
