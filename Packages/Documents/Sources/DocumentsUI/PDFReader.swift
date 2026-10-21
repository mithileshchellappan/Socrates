import StudyCore
import StudyUI
import SwiftUI
#if os(macOS)
import AppKit
import PDFKit

/// A PDF's pages in PDFKit (mt, docs/plan-materials.md §2.3; the Documents reader's page jump
/// later): one page column scrolling continuously, fit to the width up to `maxPageWidth` points
/// (times the content zoom), the content background around white pages in both appearances (as
/// slides), native selection and Copy. The host drives it through a `PDFReaderModel`: go to a page
/// (marking a passage's first words until the next click), mark search matches in the
/// highlighter, read the page in view and the selection; the context menu starts with Ask About
/// Selection when the host takes it. Mac only.
public struct PDFReader: NSViewRepresentable {
    private let model: PDFReaderModel
    private let maxPageWidth: CGFloat
    private let askAboutSelection: ((String, Int) -> Void)?
    @Environment(\.contentZoom) private var zoom
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - maxPageWidth: the widest a page is drawn at 100 % zoom.
    ///   - askAboutSelection: the context menu's Ask About Selection (the selected text, its first
    ///     page, 1-based); nil: no such item.
    public init(model: PDFReaderModel, maxPageWidth: CGFloat = 900, askAboutSelection: ((String, Int) -> Void)? = nil) {
        self.model = model
        self.maxPageWidth = maxPageWidth
        self.askAboutSelection = askAboutSelection
    }

    public func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.autoScales = false
        view.pageShadowsEnabled = true
        view.backgroundColor = .textBackgroundColor
        view.maxPageWidth = maxPageWidth
        view.zoom = zoom
        view.askAboutSelection = askAboutSelection
        model.attach(view)
        return view
    }

    public func updateNSView(_ view: ReaderPDFView, context: Context) {
        view.askAboutSelection = askAboutSelection
        if view.maxPageWidth != maxPageWidth || view.zoom != zoom {
            view.maxPageWidth = maxPageWidth
            view.zoom = zoom
            view.fitWidth()
        }
        if view.document !== model.document { model.attach(view) }
    }

    public static func dismantleNSView(_ view: ReaderPDFView, coordinator: ()) {
        view.stopFollowing()
    }
}

/// What a `PDFReader` shows and where: the host loads a file, moves to pages, marks passages and
/// search matches, and reads back the page in view (`page`, 1-based) and when scrolling rests.
@MainActor
@Observable
public final class PDFReaderModel {
    /// The open document (nil until `load`, or when the file does not open).
    public private(set) var document: PDFDocument?
    /// The page in view, 1-based (0 before the document is shown).
    public private(set) var page = 0
    /// Called 2 s after scrolling rests, with the page in view.
    @ObservationIgnored public var onRest: ((Int) -> Void)?
    @ObservationIgnored private weak var view: ReaderPDFView?
    /// Where to go once the view shows the document.
    @ObservationIgnored private var pendingPage: (page: Int, mark: String?)?
    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var cite: PDFSelection?

    public init() {}

    /// Opens the file (nothing when it does not open: `document` stays nil).
    public func load(_ url: URL) {
        guard document?.documentURL != url else { return }
        document = PDFDocument(url: url)
        page = 0
        matches = []
        cite = nil
        if let view { attach(view) }
    }

    func attach(_ view: ReaderPDFView) {
        self.view = view
        view.model = self
        guard view.document !== document else { return }
        view.document = document
        view.fitWidth()
        view.follow()
        if let pendingPage {
            self.pendingPage = nil
            go(to: pendingPage.page, mark: pendingPage.mark)
        } else {
            pageChanged()
        }
    }

    /// Scrolls to a 1-based page and marks the first words of `mark` on it (the cited passage),
    /// or of the page's first sentence when `mark` is empty and `marksFirstWords` is set, until the
    /// next click.
    public func go(to number: Int, mark: String? = nil) {
        guard let view, let document, view.document === document else {
            pendingPage = (number, mark)
            return
        }
        let index = min(max(0, number - 1), max(0, document.pageCount - 1))
        guard let target = document.page(at: index) else { return }
        cite = mark.flatMap { Self.selection(of: $0, on: target) }
        cite?.color = NSColor.controlAccentColor.withAlphaComponent(0.22)
        applyHighlights()
        if let cite {
            let bounds = cite.bounds(for: target)
            view.go(to: PDFDestination(page: target, at: CGPoint(x: 0, y: min(target.bounds(for: .cropBox).maxY, bounds.maxY + 80))))
        } else {
            view.go(to: target)
        }
        pageChanged()
    }

    /// Marks every match of `query` on `pages` (1-based) in the highlighter; empty: none.
    public func mark(query: String, pages: [Int]) {
        guard let document else { return }
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [PDFSelection] = []
        if !folded.isEmpty {
            for number in Set(pages).sorted() {
                guard let page = document.page(at: number - 1), let text = page.string else { continue }
                var range = text.startIndex..<text.endIndex
                while let hit = text.range(of: folded, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
                    if let selection = page.selection(for: NSRange(hit, in: text)) {
                        selection.color = NSColor(srgbRed: 1, green: 214 / 255, blue: 10 / 255, alpha: 0.45)
                        found.append(selection)
                    }
                    range = hit.upperBound..<text.endIndex
                    if found.count >= 400 { break }
                }
            }
        }
        matches = found
        applyHighlights()
    }

    /// The selected text and its first page (1-based), or nil.
    public var selection: (text: String, page: Int)? {
        guard let view, let selection = view.currentSelection, let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = selection.pages.first, let document = view.document
        else { return nil }
        return (text, document.index(for: first) + 1)
    }

    /// The first words of the passage, as found on the page (the first 8 words, else fewer).
    static func selection(of passage: String, on page: PDFPage) -> PDFSelection? {
        guard let text = page.string else { return nil }
        let words = passage.split(whereSeparator: \.isWhitespace)
        for count in stride(from: min(8, words.count), through: 2, by: -2) {
            let probe = words.prefix(count).joined(separator: " ")
            if let range = text.range(of: probe, options: [.caseInsensitive, .diacriticInsensitive]) {
                return page.selection(for: NSRange(range, in: text))
            }
        }
        return nil
    }

    func clearCite() {
        guard cite != nil else { return }
        cite = nil
        applyHighlights()
    }

    private func applyHighlights() {
        view?.highlightedSelections = matches + (cite.map { [$0] } ?? [])
    }

    func pageChanged() {
        guard let view, let document = view.document, let current = view.currentPage else { return }
        let number = document.index(for: current) + 1
        if number != page { page = number }
    }

    func rested() {
        pageChanged()
        if page > 0 { onRest?(page) }
    }
}

/// PDFKit's view with the reader's fit, its menu and its rest timer.
public final class ReaderPDFView: PDFView {
    weak var model: PDFReaderModel?
    var maxPageWidth: CGFloat = 900
    var zoom: CGFloat = 1
    var askAboutSelection: ((String, Int) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var restTimer: Timer?

    /// Fit to the width up to `maxPageWidth × zoom` (the first page's width decides).
    func fitWidth() {
        guard let page = document?.page(at: 0) else { return }
        let pageWidth = page.bounds(for: displayBox).width
        guard pageWidth > 0, bounds.width > 40 else { return }
        let available = bounds.width - 32
        let width = min(available, maxPageWidth * zoom)
        let factor = max(0.1, width / pageWidth)
        if abs(scaleFactor - factor) > 0.001 { scaleFactor = factor }
    }

    public override func layout() {
        super.layout()
        fitWidth()
    }

    func follow() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        })
        if let clip = enclosedScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            })
        }
    }

    func stopFollowing() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        restTimer?.invalidate()
        restTimer = nil
        model?.rested()
    }

    private var enclosedScrollView: NSScrollView? {
        subviews.lazy.compactMap { $0 as? NSScrollView }.first ?? subviews.lazy.flatMap(\.subviews).compactMap { $0 as? NSScrollView }.first
    }

    private func scrolled() {
        model?.pageChanged()
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.rested() }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        model?.clearCite()
        super.mouseDown(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard askAboutSelection != nil, model?.selection != nil else { return menu }
        let item = NSMenuItem(title: String(localized: "Ask About Selection"), action: #selector(askSelected), keyEquivalent: "")
        item.target = self
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item, at: 0)
        return menu
    }

    @objc private func askSelected() {
        guard let selection = model?.selection else { return }
        askAboutSelection?(selection.text, selection.page)
    }
}
#else
/// The iPhone has no PDF reader yet (mt: materials' files stay on the Mac).
public struct PDFReader: View {
    public init(model: PDFReaderModel, maxPageWidth: CGFloat = 900, askAboutSelection: ((String, Int) -> Void)? = nil) {}
    public var body: some View { Color.clear }
}

@MainActor
@Observable
public final class PDFReaderModel {
    public private(set) var page = 0
    public var onRest: ((Int) -> Void)?
    public init() {}
    public func load(_ url: URL) {}
    public func go(to number: Int, mark: String? = nil) {}
    public func mark(query: String, pages: [Int]) {}
}
#endif
