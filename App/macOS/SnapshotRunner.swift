#if DEBUG
import AppKit
import CoursesUI
import FilingUI
import StudyCore
import StudyUI
import SwiftUI

/// Debug builds only: renders the wired main window of a library to PNGs and quits, so the app
/// can be checked against the mockups without a screen.
///
///     STUDYPORTAL_DATA_ROOT=<library copy> STUDYPORTAL_SNAPSHOTS=<folder> StudyPortal.app/Contents/MacOS/StudyPortal
///
/// Shots (light and dark): Today, Course Settings of Data Centers, the review of DC lecture 2
/// (slide 16, 37:27) and CL lecture 1 (slide 11, 7:25), Search for "paravirtualization" and
/// "ELIZA", and the drop HUD over Today for the files in `STUDYPORTAL_SNAPSHOT_DROP` (paths
/// separated by ":"), after filing those in `STUDYPORTAL_SNAPSHOT_FILE` (their toasts). Filing
/// writes to the library: point the app at a copy.
@MainActor
enum SnapshotRunner {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["STUDYPORTAL_SNAPSHOTS"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
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
            let filed = files("STUDYPORTAL_SNAPSHOT_FILE")

            let (courses, lectures) = try await services.database.read { db in
                (try Course.all.fetchAll(db), try Lecture.all.fetchAll(db))
            }
            func lecture(_ course: String, _ number: Int) -> Lecture.ID? {
                guard let courseID = courses.first(where: { $0.name == course })?.id else { return nil }
                return lectures.first { $0.courseID == courseID && $0.number == number }?.id
            }
            var shots: [Shot] = [Shot(name: "01-today", item: .today)]
            if let cc = courses.first(where: { $0.name == "Data Centers" }) {
                shots.append(Shot(name: "08-course-settings", item: .course(cc.id)))
            }
            if let id = lecture("Data Centers", 2) {
                shots.append(Shot(name: "03-review-dc-l2", item: .lecture(id), target: (id, ReviewTarget(page: 16, time: 2247)), size: CGSize(width: 1440, height: 900)))
            }
            if let id = lecture("Computational Linguistics", 1) {
                shots.append(Shot(name: "03-review-cl-l1", item: .lecture(id), target: (id, ReviewTarget(page: 11, time: 445)), size: CGSize(width: 1440, height: 900)))
            }
            shots.append(Shot(name: "07-search-paravirtualization", item: .search, query: "paravirtualization"))
            shots.append(Shot(name: "07-search-eliza", item: .search, query: "ELIZA"))
            let drop = files("STUDYPORTAL_SNAPSHOT_DROP")
            if !drop.isEmpty || !filed.isEmpty {
                shots.append(Shot(name: "10-import", item: .today, drop: drop, file: filed, settle: .seconds(1.5)))
            }

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

    /// Hosts the main window's content in a titled window off screen (never ordered in: an
    /// ordered-in window on a locked or sleeping display is occluded and stops drawing its scroll
    /// views), lets it settle, and draws the whole window, toolbar included.
    static func render(_ shot: Shot, scheme: ColorScheme, model: AppModel, to url: URL) async throws {
        let root = RootView(selection: shot.item, query: shot.query, reviewTarget: shot.target)
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
        try await Task.sleep(for: shot.settle)
        if !shot.drop.isEmpty, let center = model.filingCenter {
            await center.previewDrag(shot.drop, at: CGPoint(x: shot.size.width * 0.42, y: shot.size.height * 0.36))
            try await Task.sleep(for: .seconds(0.5))
        }
        defer { model.filingCenter?.endPreviewDrag() }
        let frame = window.contentView?.superview ?? host
        frame.layoutSubtreeIfNeeded()
        frame.display()
        guard let png = composite(frame) else { return }
        try png.write(to: url)
    }

    /// The window drawn piece by piece: `cacheDisplay` of the whole window leaves out what sits
    /// in Liquid Glass containers (the sidebar, the inspector) and the split view's columns, so
    /// each column's hosting view is drawn on its own over the window chrome, and the title bar
    /// (title, toolbar) last, on top.
    static func composite(_ frame: NSView) -> Data? {
        guard let canvas = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: canvas)
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        // Hosting views in tree order (the window's, the columns', list cells'), then the title bar.
        var hosts: [NSView] = []
        var titlebars: [NSView] = []
        func collect(_ view: NSView) {
            let name = String(describing: type(of: view))
            if name.hasPrefix("NSHostingView<") || name.hasPrefix("CellHostingView<") || name == "PlatformGroupContainer" {
                hosts.append(view)
            } else if name == "NSTitlebarContainerView" {
                titlebars.append(view)
            }
            for sub in view.subviews where !sub.isHidden { collect(sub) }
        }
        collect(frame)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for view in hosts + titlebars {
            // Only what shows: rows scrolled under the title bar or out of the list stay clipped.
            let rect = view.visibleRect
            guard rect.width > 1, rect.height > 1, let piece = view.bitmapImageRepForCachingDisplay(in: rect) else { continue }
            view.cacheDisplay(in: rect, to: piece)
            piece.draw(in: view.convert(rect, to: frame), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
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
