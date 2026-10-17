import AppKit
import CaptureUI
import FilingUI
import SearchUI
import StudyCore
import StudyUI
import SwiftUI

// parity-render: the six mockup screens of a parity library copy, drawn off screen.
//
//   tools/parity/render [--library DIR] [--out DIR] [--only 01-today,03-review]
//                       [--appearance light|dark|both] [--settle SECONDS]
//
// Builds the app's real views (`RootView` with its sidebar and toolbar, `LiveLectureScreen`) in
// windows that are never ordered on screen, at the mockups' 1440×900 points, and writes
// <out>/<screen>-<appearance>.png (2×). The process has no Dock icon and never activates, so it
// can run while the Mac is in use. The library is cloned first (nothing is written to it) and
// the real library is refused (`ParityMode.services`). Off-screen pictures lack Liquid Glass and
// vibrancy and show controls as in an inactive window.

/// The repository root, from this file's location (tools/ParityRender/Sources/ParityRender/).
let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

struct RenderOptions {
    var library = repository.appending(path: ".data/parity/library", directoryHint: .isDirectory)
    var output = repository.appending(path: ".data/parity/offscreen/latest", directoryHint: .isDirectory)
    var only: Set<String>?
    var schemes: [ColorScheme] = [.light, .dark]
    var settle: Duration = .seconds(3)

    init(arguments: [String]) throws {
        var index = 0
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw RenderFailure("\(arguments[index - 1]) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--library": library = URL(filePath: try value(), directoryHint: .isDirectory).standardizedFileURL
            case "--out": output = URL(filePath: try value(), directoryHint: .isDirectory).standardizedFileURL
            case "--only": only = Set(try value().split(separator: ",").map(String.init))
            case "--settle": settle = .seconds(Double(try value()) ?? 3)
            case "--appearance":
                switch try value() {
                case "light": schemes = [.light]
                case "dark": schemes = [.dark]
                default: schemes = [.light, .dark]
                }
            default: throw RenderFailure("unknown argument \(arguments[index])")
            }
            index += 1
        }
    }
}

struct RenderFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// One screen: what the window shows, and what happens once it has settled (a previewed drag).
struct RenderShot {
    enum Window {
        case main(ParityMode.Launch)
        case live
    }

    var name: String
    var window: Window
    var prepare: ((AppModel, CGSize) async throws -> Void)?
}

@main
struct ParityRender {
    static func main() {
        let app = NSApplication.shared
        // No Dock icon, no menu bar, never the active app.
        app.setActivationPolicy(.prohibited)
        Task {
            do {
                let options = try RenderOptions(arguments: Array(CommandLine.arguments.dropFirst()))
                try await render(options)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("parity-render: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    static func render(_ options: RenderOptions) async throws {
        let size = ParityMode.windowSize
        let copy = URL.temporaryDirectory.appending(path: "ParityRender-\(UUID().uuidString)", directoryHint: .isDirectory)
        // An APFS clone: every run starts from the same data; nothing is written to the library.
        try FileManager.default.copyItem(at: options.library, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let parity = ParityMode.Options(
            route: .today, routeText: "today", dataRoot: copy, appearance: nil, readyMarker: nil, settle: options.settle
        )
        let services = try ParityMode.services(parity)
        prepareDependencies { $0.defaultDatabase = services.database }
        let model = AppModel(services: services, startsProcessing: false)
        if let indexer = model.searchIndexer { _ = try await indexer.catchUp(verifyingText: true) }
        await model.filing?.repairDeckTitles()
        // The search screen as if it had been searched (↩): listed under Recent searches. In the
        // registration domain, so nothing is written to any defaults file.
        var recent = RecentSearches(storage: "")
        recent.record("paravirtualization")
        UserDefaults.standard.register(defaults: [RecentSearches.storageKey: recent.storage])

        let cc = try ParityMode.course("Data Centers", services: services)
        let (_, dcLecture2) = try ParityMode.lecture("Data Centers", 2, services: services)
        var shots: [RenderShot] = [
            RenderShot(name: "01-today", window: .main(ParityMode.Launch(selection: .today))),
            RenderShot(name: "02-live", window: .live),
            // 37:27, the mockup's moment: slide 16 holds the playhead, so Follow is on.
            RenderShot(name: "03-review", window: .main(ParityMode.Launch(
                selection: .lecture(dcLecture2.id),
                reviewTarget: (dcLecture2.id, ReviewTarget(page: 16, time: 2247, request: UUID()))
            ))),
            RenderShot(name: "07-search", window: .main(ParityMode.Launch(selection: .search, query: "paravirtualization"))),
            RenderShot(name: "08-course", window: .main(ParityMode.Launch(selection: .courseSettings(cc.id)))),
            RenderShot(name: "10-import", window: .main(ParityMode.Launch(selection: .today))) { model, size in
                try await ParityMode.importPreview(model: model, services: services, size: size)
            }
        ]
        if let only = options.only { shots = shots.filter { only.contains($0.name) } }
        // The live screen last: its preview session keeps "recording", and a running recording
        // shows in every main window's toolbar.
        shots = shots.filter { !isLive($0) } + shots.filter(isLive)
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)

        for shot in shots {
            if case .live = shot.window {
                let capture = try await ParityMode.livePreview("Data Centers", 2, slide: 17, services: services)
                model.showPreviewCapture(capture)
            }
            for scheme in options.schemes {
                let url = options.output.appending(path: "\(shot.name)-\(scheme == .dark ? "dark" : "light").png")
                try await draw(shot, scheme: scheme, model: model, size: size, settle: options.settle, to: url)
                print(url.path(percentEncoded: false))
            }
            model.filingCenter?.endPreviewDrag()
            model.filingCenter?.toasts.map(\.id).forEach { model.filingCenter?.dismiss($0) }
        }
    }

    static func isLive(_ shot: RenderShot) -> Bool {
        if case .live = shot.window { return true }
        return false
    }

    /// Hosts the shot's window content in a titled window off screen (never ordered in), lets it
    /// settle, runs its preparation, and draws the whole window, toolbar included
    /// (`SnapshotRunner.composite`).
    static func draw(_ shot: RenderShot, scheme: ColorScheme, model: AppModel, size: CGSize, settle: Duration, to url: URL) async throws {
        let content: AnyView
        switch shot.window {
        case .main(let launch):
            content = AnyView(
                RootView(selection: launch.selection, query: launch.query, reviewTarget: launch.reviewTarget)
                    .environment(model)
            )
        case .live:
            content = AnyView(LiveLectureScreen().environment(model))
        }
        let host = NSHostingView(rootView: content)
        host.sceneBridgingOptions = .all
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(size)
        defer { window.close() }
        // Vibrant dark draws its text through compositing filters an off-screen bitmap does not
        // apply: plain dark instead (as `SnapshotRunner` does).
        func devibrant(_ view: NSView) {
            if view.effectiveAppearance.name == .vibrantDark { view.appearance = NSAppearance(named: .darkAqua) }
            view.subviews.forEach(devibrant)
        }
        let frame = window.contentView?.superview ?? host
        if scheme == .dark {
            frame.layoutSubtreeIfNeeded()
            devibrant(frame)
        }
        try await Task.sleep(for: settle)
        if let prepare = shot.prepare {
            try await prepare(model, size)
            try await Task.sleep(for: .seconds(1.5))
        }
        if scheme == .dark {
            devibrant(frame)
            try await Task.sleep(for: .milliseconds(300))
        }
        frame.layoutSubtreeIfNeeded()
        frame.display()
        guard let png = SnapshotRunner.composite(frame) else { throw RenderFailure("\(shot.name): nothing drawn") }
        try png.write(to: url)
    }
}
