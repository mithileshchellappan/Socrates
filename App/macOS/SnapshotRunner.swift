#if DEBUG
import AppKit
import CoursesUI
import PDFKit
import FilingUI
import StudyCore
import StudyUI
import StudyPageUI
import SwiftUI

/// Debug builds only: renders the wired main window of a library to PNGs and quits, so the app
/// can be checked against the mockups without a screen.
///
///     SOCRATES_DATA_ROOT=<library copy> SOCRATES_SNAPSHOTS=<folder> Socrates.app/Contents/MacOS/Socrates
///
/// Shots (light and dark): Today, Calendar (the week of `SOCRATES_SNAPSHOT_WEEK`, YYYY-MM-DD, else
/// this week), Mail (Inbox with the newest message, its course, Drafts), Course
/// Settings of DC, the review of DC lecture 2
/// (slide 16, 37:27) and CL lecture 1 (slide 11, 7:25), Search for "paravirtualization" and
/// "ELIZA", and the drop HUD over Today for the files in `SOCRATES_SNAPSHOT_DROP` (paths
/// separated by ":"), after filing those in `SOCRATES_SNAPSHOT_FILE` (their toasts). Filing
/// writes to the library: point the app at a copy.
@MainActor
enum SnapshotRunner {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["SOCRATES_SNAPSHOTS"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func files(_ key: String) -> [URL] {
        (ProcessInfo.processInfo.environment[key] ?? "")
            .split(separator: ":")
            .map { URL(filePath: String($0)) }
    }

    struct Shot {
        var name: String
        var item: SidebarItem
        var query = ""
        var target: (lectureID: Lecture.ID, target: ReviewTarget)?
        /// The message selected on Mail.
        var message: MailMessage.ID?
        var drop: [URL] = []
        /// Filed just before the shot (its toasts show).
        var file: [URL] = []
        var size = CGSize(width: 1180, height: 760)
        var settle: Duration = .seconds(3)
    }

    static func run(model: AppModel) async {
        guard let directory, let services = model.services else { return }
        // No App Nap while the off-screen windows render (nothing of the app is visible).
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Rendering snapshots")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let log = Log.logger(category: "snapshots")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let indexer = model.searchIndexer { _ = try await indexer.catchUp() }
            // What a launch does to an older library before the window shows it.
            await model.filing?.repairDeckTitles()
            let filed = files("SOCRATES_SNAPSHOT_FILE")

            let (courses, lectures) = try await services.database.read { db in
                (try Course.all.fetchAll(db), try Lecture.all.fetchAll(db))
            }
            // Courses by short name ("DC", "CL"), whatever the library calls them.
            func lecture(_ course: String, _ number: Int) -> Lecture.ID? {
                guard let courseID = courses.first(where: { $0.shortName == course })?.id else { return nil }
                return lectures.first { $0.courseID == courseID && $0.number == number }?.id
            }
            var shots: [Shot] = [Shot(name: "01-today", item: .today), Shot(name: "06-calendar", item: .calendar)]
            model.fixedCalendarWeek = ProcessInfo.processInfo.environment["SOCRATES_SNAPSHOT_WEEK"].flatMap(CalendarDay.init(rawValue:))
            if let dc = courses.first(where: { $0.shortName == "DC" }) {
                shots.append(Shot(name: "08-course-settings", item: .courseSettings(dc.id)))
            }
            if let id = lecture("DC", 2) {
                shots.append(Shot(name: "03-review-dc-l2", item: .lecture(id), target: (id, ReviewTarget(page: 16, time: 2247)), size: CGSize(width: 1440, height: 900)))
            }
            if let id = lecture("CL", 1) {
                shots.append(Shot(name: "03-review-cl-l1", item: .lecture(id), target: (id, ReviewTarget(page: 11, time: 445)), size: CGSize(width: 1440, height: 900)))
            }
            // Mail (mockup 05): the Inbox with its newest message, a course's mail, Drafts.
            let newest = try await services.database.read { db in
                try MailMessage.order { $0.receivedAt.desc() }.fetchOne(db)
            }
            shots.append(Shot(name: "05-mail", item: .mailScope(.inbox), message: newest?.id))
            if let courseID = newest?.courseID {
                shots.append(Shot(name: "05-mail-course", item: .mailScope(.course(courseID))))
            }
            shots.append(Shot(name: "05-mail-drafts", item: .mailScope(.drafts)))
            shots.append(Shot(name: "07-search-paravirtualization", item: .search, query: "paravirtualization"))
            shots.append(Shot(name: "07-search-eliza", item: .search, query: "ELIZA"))
            let drop = files("SOCRATES_SNAPSHOT_DROP")
            if !drop.isEmpty || !filed.isEmpty {
                shots.append(Shot(name: "10-import", item: .today, drop: drop, file: filed, settle: .seconds(1.5)))
            }

            try menuShortcuts().write(to: directory.appending(path: "menus.txt"), atomically: true, encoding: .utf8)

            for shot in shots {
                // Confident toasts leave after 8 s: both pictures are taken before that.
                if !shot.file.isEmpty, let center = model.filingCenter { await center.file(shot.file) }
                for scheme in [ColorScheme.light, .dark] {
                    let url = directory.appending(path: shot.name + (scheme == .dark ? "-dark" : "") + ".png")
                    try await render(shot, scheme: scheme, model: model, to: url)
                    log.info("Wrote \(url.lastPathComponent, privacy: .public)")
                }
            }
        } catch {
            log.error("Snapshots failed: \(String(describing: error), privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    /// Every menu item with a key equivalent ("Review ▸ Next Slide  →"), then the equivalents
    /// two items share (they must never be enabled in the same window at once).
    static func menuShortcuts() -> String {
        var lines: [String] = []
        var seen: [String: [String]] = [:]
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items {
                let title = path.isEmpty ? item.title : "\(path) ▸ \(item.title)"
                if let submenu = item.submenu { walk(submenu, path: title) }
                guard !item.keyEquivalent.isEmpty else { continue }
                let flags = item.keyEquivalentModifierMask
                let key = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                    + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
                    + Self.keyName(item.keyEquivalent)
                lines.append("\(title)  \(key)")
                seen[key, default: []].append(title)
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, path: "") }
        let shared = seen.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        lines.append("")
        lines.append("Shared key equivalents:")
        lines += shared.map { "  \($0.key): \($0.value.joined(separator: " | "))" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func keyName(_ key: String) -> String {
        switch key.unicodeScalars.first.map({ Int($0.value) }) {
        case NSLeftArrowFunctionKey: "←"
        case NSRightArrowFunctionKey: "→"
        case NSUpArrowFunctionKey: "↑"
        case NSDownArrowFunctionKey: "↓"
        case 0x20: "Space"
        case 0x1B: "⎋"
        case 0x0D, 0x03: "↩"
        case 0x7F, 0x08: "⌫"
        default: key.uppercased()
        }
    }

    /// Hosts the main window's content in a titled window off screen (never ordered in: an
    /// ordered-in window on a locked or sleeping display is occluded and stops drawing its scroll
    /// views), lets it settle, and draws the whole window, toolbar included.
    static func render(_ shot: Shot, scheme: ColorScheme, model: AppModel, to url: URL) async throws {
        let root = RootView(selection: shot.item, query: shot.query, reviewTarget: shot.target, mailSelection: shot.message)
            // ln: opening a lecture's notes never queues them in a render.
            .environment(\.lectureNotesQueuesOnOpen, false)
            .environment(model)
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = .all
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: shot.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(shot.size)
        defer { window.close() }
        // Vibrant dark (sidebar, toolbar) draws its text through compositing filters that an
        // off-screen bitmap does not apply (black text on white glass): plain dark instead, set
        // before the content first renders and again once it has settled.
        func devibrant(_ view: NSView) {
            if view.effectiveAppearance.name == .vibrantDark { view.appearance = NSAppearance(named: .darkAqua) }
            view.subviews.forEach(devibrant)
        }
        if scheme == .dark {
            let themeFrame = window.contentView?.superview ?? host
            themeFrame.layoutSubtreeIfNeeded()
            devibrant(themeFrame)
        }
        try await Task.sleep(for: shot.settle)
        if !shot.drop.isEmpty, let center = model.filingCenter {
            await center.previewDrag(shot.drop, at: CGPoint(x: shot.size.width * 0.42, y: shot.size.height * 0.36))
            try await Task.sleep(for: .seconds(0.5))
        }
        defer { model.filingCenter?.endPreviewDrag() }
        let frame = window.contentView?.superview ?? host
        if scheme == .dark {
            devibrant(frame)
            try await Task.sleep(for: .milliseconds(300))
        }
        frame.layoutSubtreeIfNeeded()
        frame.display()
        guard let png = composite(frame) else { return }
        try png.write(to: url)
    }

    /// The window drawn piece by piece: `cacheDisplay` of the whole window leaves out what sits
    /// in Liquid Glass containers (the sidebar, the inspector) and the split view's columns, so
    /// each column's hosting view is drawn on its own over the window chrome, and the title bar
    /// (title, toolbar) last, on top.
    ///
    /// Everything is drawn in the window's appearance (`cacheDisplay` outside it draws light
    /// colours into a dark window) over the window background colour (the cached window alone is
    /// transparent where the columns are), so the dark shots show dark mode.
    static func composite(_ frame: NSView) -> Data? {
        var png: Data?
        (frame.window?.effectiveAppearance ?? frame.effectiveAppearance).performAsCurrentDrawingAppearance {
            png = drawComposite(frame)
        }
        return png
    }

    private static func drawComposite(_ frame: NSView) -> Data? {
        guard let chrome = frame.bitmapImageRepForCachingDisplay(in: frame.bounds),
              let canvas = frame.bitmapImageRepForCachingDisplay(in: frame.bounds),
              let context = NSGraphicsContext(bitmapImageRep: canvas)
        else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: chrome)
        let isDark = frame.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Hosting views in tree order (the window's, the columns', list cells'), then the title bar.
        // Dark only: Liquid Glass (sidebar, toolbar platters) draws as white off screen, so its
        // area is filled with a dark surface and what sits on it is drawn again on top.
        var hosts: [NSView] = []
        var titlebars: [NSView] = []
        var sidebarGlass: [NSView] = []
        var titlebarGlass: [NSView] = []
        var overTitlebarGlass: [NSView] = []
        var pdfViews: [PDFView] = []
        func collect(_ view: NSView, inTitlebar: Bool) {
            let name = String(describing: type(of: view))
            let titlebar = inTitlebar || name == "NSTitlebarContainerView"
            if let pdf = view as? PDFView { pdfViews.append(pdf) }
            // panes: a maximized pane's slot covers the screen and the other panes; what it covers
            // is drawn only by the chrome (in z-order), never again on top.
            if name == "PaneSlotView" {
                let slot = view.convert(view.bounds, to: frame)
                hosts.removeAll { slot.contains($0.convert($0.visibleRect, to: frame)) }
            }
            if name.hasPrefix("NSHostingView<") || name.hasPrefix("CellHostingView<") || name == "PlatformGroupContainer" {
                hosts.append(view)
            } else if name == "NSTitlebarContainerView" {
                titlebars.append(view)
            }
            if isDark {
                if name.hasSuffix("GlassEffectView") {
                    if titlebar { titlebarGlass.append(view) } else { sidebarGlass.append(view) }
                } else if titlebar, name == "NSToolbarItemViewer" || name == "NSToolbarTitleView" || name.hasPrefix("_NSCoreHostingView<") {
                    overTitlebarGlass.append(view)
                }
            }
            for sub in view.subviews where !sub.isHidden { collect(sub, inTitlebar: titlebar) }
        }
        collect(frame, inTitlebar: false)

        func draw(_ views: [NSView]) {
            for view in views {
                // Only what shows: rows scrolled under the title bar or out of the list stay clipped.
                let rect = view.visibleRect
                guard rect.width > 1, rect.height > 1, let piece = view.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                view.cacheDisplay(in: rect, to: piece)
                piece.draw(in: view.convert(rect, to: frame), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        func fill(_ views: [NSView], _ color: NSColor) {
            color.setFill()
            for view in views {
                let rect = view.convert(view.bounds, to: frame)
                NSBezierPath(roundedRect: rect, xRadius: min(14, rect.height / 2), yRadius: min(14, rect.height / 2)).fill()
            }
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        frame.bounds.fill()
        chrome.draw(in: frame.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        fill(sidebarGlass, NSColor(white: 0.16, alpha: 1))
        draw(hosts)
        drawPages(pdfViews, in: frame)
        draw(titlebars)
        fill(titlebarGlass, NSColor(white: 0.24, alpha: 1))
        draw(overTitlebarGlass)
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }

    /// mt: PDFKit draws its pages in layers an off-screen cache leaves out (the material reader):
    /// the visible pages are drawn here, white paper with its shadow on the view's background, the
    /// highlighted selections (search hits, the cited passage) over them.
    private static func drawPages(_ views: [PDFView], in frame: NSView) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for pdf in views {
            guard let container = pdf.superview else { continue }
            let visible = container.convert(pdf.frame, to: frame)
            pdf.backgroundColor.setFill()
            visible.fill()
            for page in pdf.visiblePages {
                let box = page.bounds(for: pdf.displayBox)
                let rect = pdf.convert(pdf.convert(box, from: page), to: frame)
                context.saveGState()
                context.clip(to: visible)
                context.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.25).cgColor)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(rect)
                context.setShadow(offset: .zero, blur: 0, color: nil)
                context.translateBy(x: rect.minX, y: frame.isFlipped ? rect.maxY : rect.minY)
                context.scaleBy(x: rect.width / box.width, y: (frame.isFlipped ? -1 : 1) * rect.height / box.height)
                context.translateBy(x: -box.minX, y: -box.minY)
                page.draw(with: pdf.displayBox, to: context)
                // Multiplied, as a highlighter marks paper: the words stay readable.
                context.setBlendMode(.multiply)
                for selection in pdf.highlightedSelections ?? [] where selection.pages.contains(page) {
                    context.setFillColor((selection.color ?? .yellow).cgColor)
                    context.fill(selection.bounds(for: page))
                }
                context.restoreGState()
            }
        }
    }
}

/// The main window's stand-in while snapshots render.
struct SnapshotRunnerView: View {
    let model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 10, height: 10)
            .task { await SnapshotRunner.run(model: model) }
    }
}
#endif
