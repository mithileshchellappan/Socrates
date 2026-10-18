import AppKit
import CaptureUI
import ClaudeKit
import FilingUI
import MailIntelligence
import ReviewUI
import SearchUI
import StudyCore
import StudyUI
import SwiftUI

// parity-render: the six mockup screens of a parity library copy, drawn off screen.
//
//   tools/parity/render [--library DIR] [--out DIR] [--only 01-today,03-review]
//                       [--appearance light|dark|both] [--settle SECONDS] [--now 2026-10-16T15:02]
//                       [--week 2026-10-19] [--m35-sample]
//
// `06-calendar` opens on the week of `--week` (default: mockup 06's, Mon 19 Oct 2026); `--now`
// also fixes Today's clock (the DemoLibrary's is 2026-10-16T09:41, its mail's 15:02).
//
// `05-mail` (Mail: the Inbox with its newest message selected) needs a library with mail, e.g.
// the sample library `swift run --package-path tools/EndToEnd m1-e2e demo --library DIR` writes
// (mockup 05's mail) or the m2-e2e library; `--now` fixes the clock the mail list's times are
// relative to (the university's time zone).
//
// `--m35-sample` (a library with mockup 05's mail, e.g. .data/parity/m3/library): adds M3.5's
// sample rows to the clone (an open task, a mail that needs a reply, a mail chat about the newest
// mail) and draws with Claude Code available, so Today and Mail show Show Chat; it adds the shots
// `01-today-chat` and `05-mail-chat` (the chat inspector open), and M5's `07-search-chat` and
// `03-review-chat` (seed the copy with `tools/parity/seed --library <copy> --m5-sample` first).
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
    /// The "now" of screens that show times relative to today (Mail's list, Today, Calendar).
    var now: Date?
    /// The week Calendar shows (mockup 06: Week 43).
    var week = CalendarDay(year: 2026, month: 10, day: 19)
    /// M3.5's sample rows and Claude Code available (`--m35-sample`).
    var m35Sample = false

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
            case "--now":
                let text = try value()
                guard let day = CalendarDay(rawValue: String(text.prefix(10))) else { throw RenderFailure("--now takes 2026-10-16T15:02") }
                let parts = text.dropFirst(11).split(separator: ":").compactMap { Int($0) }
                let zone = TimeZone(identifier: "Europe/Lisbon") ?? .current
                now = day.date(minute: parts.count == 2 ? parts[0] * 60 + parts[1] : 0, in: zone)
            case "--week":
                guard let day = CalendarDay(rawValue: try value()) else { throw RenderFailure("--week takes 2026-10-19") }
                week = day
            case "--m35-sample": m35Sample = true
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
        model.fixedNow = options.now
        model.fixedCalendarWeek = options.week
        if let indexer = model.searchIndexer { _ = try await indexer.catchUp(verifyingText: true) }
        await model.filing?.repairDeckTitles()
        // The search screen as if it had been searched (↩): listed under Recent searches. In the
        // registration domain, so nothing is written to any defaults file.
        var recent = RecentSearches(storage: "")
        recent.record("paravirtualization")
        UserDefaults.standard.register(defaults: [RecentSearches.storageKey: recent.storage])

        let newestMail = try await services.database.read { db in
            try MailMessage
                .where { $0.mailboxID.in(Mailbox.where { $0.role.eq(MailboxRole?.some(.inbox)) }.select(\.id)) }
                .order { $0.receivedAt.desc() }
                .fetchOne(db)?.id
        }
        if options.m35Sample {
            try await seedM35(services: services, newestMail: newestMail, now: options.now ?? Date())
            model.claudeAvailability = .ready(ClaudeBackendStatus(kind: .claudeCode, version: "2.1.268", subscription: "team"))
        }
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
            RenderShot(name: "06-calendar", window: .main(ParityMode.Launch(selection: .calendar))),
            RenderShot(name: "07-search", window: .main(ParityMode.Launch(selection: .search, query: "paravirtualization"))),
            // Mockup 05: the Inbox, its newest message selected.
            RenderShot(name: "05-mail", window: .main(ParityMode.Launch(selection: .mailScope(.inbox), mailSelection: newestMail))),
            // M3.5: the chat open (with `--m35-sample` only: it needs Claude Code available).
            RenderShot(name: "01-today-chat", window: .main(ParityMode.Launch(selection: .today, showsChat: true))),
            RenderShot(name: "05-mail-chat", window: .main(ParityMode.Launch(
                selection: .mailScope(.inbox), mailSelection: newestMail, showsChat: true
            ))),
            // M5 (with `--m35-sample` on a copy seeded by `tools/parity/seed --m5-sample`): mockup
            // 07's query with the tutor shown, and DC L2 at 37:27 with the chat shown (Review's
            // Tutor tab once wired). Each draws what the app has wired so far.
            RenderShot(name: "07-search-chat", window: .main(ParityMode.Launch(
                selection: .search, query: "Nachteil Paravirtualisierung", showsChat: true
            ))),
            RenderShot(name: "03-review-chat", window: .main(ParityMode.Launch(
                selection: .lecture(dcLecture2.id),
                reviewTarget: (dcLecture2.id, ReviewTarget(page: 16, time: 2247, request: UUID())),
                showsChat: true
            ))),
            RenderShot(name: "08-course", window: .main(ParityMode.Launch(selection: .courseSettings(cc.id)))),
            RenderShot(name: "10-import", window: .main(ParityMode.Launch(selection: .today))) { model, size in
                try await ParityMode.importPreview(model: model, services: services, size: size)
            }
        ]
        if !options.m35Sample { shots = shots.filter { !$0.name.hasSuffix("-chat") } }
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

    /// M3.5's sample rows in the clone: the second-newest inbox mail asks the student something
    /// (`needs_reply`), an open undated task, and a finished mail chat about the newest mail (the
    /// student's question with that mail as its `<mail>` context, the agent's answer, a second
    /// exchange). Synthetic text; no model call.
    static func seedM35(services: StudyServices, newestMail: MailMessage.ID?, now: Date) async throws {
        let inbox = try await services.database.read { db in
            try MailMessage
                .where { $0.mailboxID.in(Mailbox.where { $0.role.eq(MailboxRole?.some(.inbox)) }.select(\.id)) }
                .order { $0.receivedAt.desc() }
                .limit(4)
                .fetchAll(db)
        }
        guard let newest = inbox.first(where: { $0.id == newestMail }) ?? inbox.first else { return }
        let asking = inbox.dropFirst(3).first ?? newest
        let stamp = now
        try await services.database.write { db in
            try MailMessage.find(asking.id).update {
                $0.needsReply = Bool?.some(true)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
        try await services.records.save(TrackedItem(
            courseID: newest.courseID, kind: .task, title: "Choose a tutorial group",
            createdBy: .agent, createdAt: now.addingTimeInterval(-3 * 3600), updatedAt: now.addingTimeInterval(-3 * 3600)
        ))

        let conversations = ConversationRepository(store: services.records)
        let started = now.addingTimeInterval(-20 * 60)
        let chat = try await conversations.start(AgentConversation(
            kind: .mailChat, title: "When is sheet 1 due?", model: ClaudeModel.opus55.rawValue, state: .finished,
            createdAt: started, updatedAt: started
        ))
        let envelope = MailEnvelope.render(newest, id: newest.id.uuidString.lowercased(), budget: MailEnvelope.Budget.drafting)
        let turns: [(AgentRole, MessageParam)] = [
            (.user, .user([.text(TextBlock(text: envelope)), .text(TextBlock(text: "When is sheet 1 due, and when do the tutorials start?"))])),
            (.assistant, .assistant([.text(TextBlock(text: "Sheet 1 is due **Thu 29 Oct, 23:59**, submitted online under Exercises › Sheet 01. Tutorials start **Fri 23 Oct, 12:15**. Both are already on Today."))])),
            (.user, .user("Draft a short reply thanking Cy.")),
            (.assistant, .assistant([.text(TextBlock(text: "The draft is under Lena’s mail, for you to edit and send."))]))
        ]
        for (role, turn) in turns {
            _ = try await conversations.append(to: chat.id, role: role, message: try turn.json.serializedString())
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
                RootView(
                    selection: launch.selection, query: launch.query, reviewTarget: launch.reviewTarget,
                    mailSelection: launch.mailSelection, showsChat: launch.showsChat
                )
                .environment(\.reviewInspectorTab, launch.reviewInspectorTab)
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
