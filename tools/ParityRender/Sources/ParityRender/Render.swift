import AppKit
import CalendarUI
import CaptureUI
import ChatUI
import ClaudeKit
import Coach
import CoachUI
import FilingUI
import ReviewUI
import SearchUI
import StudyCore
import StudyUI
import SwiftUI

// parity-render: the six mockup screens of a parity library copy, drawn off screen.
//
//   tools/parity/render [--library DIR] [--out DIR] [--only 01-today,03-review]
//                       [--appearance light|dark|both] [--settle SECONDS] [--now 2026-10-16T15:02]
//                       [--week 2026-10-19] [--m35-sample] [--mc] [--sweep] [--claude]
//                       [--review-layout 0.5,1,0] [--size 1800x1130] [--panel-width 560]
//
// `--size` draws the windows at that size in points (default the mockups' 1440×900); the PNG's
// name gets the size (`08-course-1800x1130-light.png`). A window whose columns' minimums do not
// fit grows (the PNG is then wider than asked: a layout bug). `--panel-width` is the expanded
// agent panel's stored width (`agent.panel.width`, in the registration domain). With
// `--m35-sample` on a `--ma-sample` copy, `ma-course-expanded`, `ma-mail-expanded` and
// `ma-review-expanded` are DC's Course Settings, the Inbox and DC L2's review with the panel as the
// window's right sidebar (the window layout: no column under its minimum or cut off).
//
// `03-review-cl` (a library with Computational Linguistics L1, e.g. the M1 library): that review
// where it left off. `--review-layout` sets Review's stored layout ("share,transcript,rail", 1 =
// collapsed) in the registration domain (nothing is written to any defaults file).
//
// `--sweep` (any library, empty or full; no Data Centers lecture needed): `today`, `calendar`,
// `mail`, `mail-selected`, `notes`, `notes-selected`, `study`, the agent panel (`panel-compact-new`,
// `panel-compact-latest`, `panel-expanded-latest`) and every course's `c<i>-lectures`, `-slides`,
// `-notes`, `-progress`. `--claude` draws with Claude Code available (the launcher and panel show).
//
// `--mc` (mc, the study coach; a copy seeded with `tools/parity/seed --mc-sample` / `--mc-runway`,
// e.g. .data/parity/mc/<state>/library): only the coach's shots the library has, with a coach that
// is never started (its previews read at `--now`; nothing is sent): `11-today-plan`,
// `12-today-travel` (Today), `13-study`, `14-course-progress`, `15-quiz-4` / `15-quiz-7` (the open
// rounds at question 4 and 7), `17-practice-exam-start` (Progress with the sheet drawn on top),
// `18-practice-exam-2` / `18-practice-exam-8` (the open exams at question 2 and 8),
// `19-practice-exam-results` (DC's latest handed-in exam). Pick per state with `--only`.
//
// md (the document bank; a copy of .data/parity/docs/library, `tools/parity/seed --docs-sample`):
// `md-documents` (the Modulhandbuch selected), `md-documents-cv` (the CV, Word),
// `md-documents-pending` (the letter whose summary is pending), `md-search` (Search "Prüfung" with
// the Documents group); on a library without documents `md-documents-empty`.
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
// sample rows to the clone (an open task, a mail that needs a reply) and draws with Claude Code
// available, so the agent panel's launcher shows. On a copy seeded with
// `tools/parity/seed --library <copy> --ma-sample` it adds the agent panel's shots (ma, mockup
// agent-panel-mockups.html §1–4): `ma-review` (compact, on DC L2 slide 12 at 29:44, the Weekend
// plan's first exchange), `ma-review-reopened` (compact as ⌘J opens it again: the conversation's
// latest exchange), `ma-calendar` (compact on Week 43, the same exchange), `ma-calendar-expanded`
// (the right sidebar: the whole Weekend plan with the 7 change rows) and `ma-today-files`
// (compact on Today, the QEMU conversation with its file tiles).
//
// `--calendar-sample` (a library with mockup 06's rows, e.g. .data/parity/m3/library): adds an
// exam review from a timetable file (Mon 19 Oct, 11:00), a Data Centers exam (Fri 23 Oct,
// 09:00, two rooms) and study-pass rows for DC Lecture 2 to the clone, and the shots
// `06-calendar-session` (the week's first session with a lecture, its detail popover drawn
// inline: render with `--week 2026-10-12`) and `06-calendar-exam` (the week's exam).
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
    /// Calendar's detail popovers with sample exam rows (`--calendar-sample`).
    var calendarSample = false
    /// Only the study coach's shots (`--mc`).
    var mc = false
    /// Every screen of any library, empty or full (`--sweep`), with Claude Code available (`--claude`).
    var sweep = false
    var claude = false
    /// Review's stored layout ("0.5,1,0": slide share, transcript collapsed, rail collapsed), as
    /// `@AppStorage("review.layout")` would have it (`--review-layout`).
    var reviewLayout: String?
    /// The windows' size in points (`--size 1800x1130`); nil: the mockups' size.
    var windowSize: CGSize?
    /// The expanded agent panel's stored width (`--panel-width`).
    var panelWidth: Double?

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
                guard let day = CalendarDay(rawValue: String(text.prefix(10))) else { throw RenderFailure("--now takes 2026-10-16T15:02 or 2027-01-19T09:13:55") }
                let parts = text.dropFirst(11).split(separator: ":").compactMap { Int($0) }
                let zone = TimeZone(identifier: "Europe/Lisbon") ?? .current
                // HH:MM, or HH:MM:SS (mc: the practice exam's clock at 09:13:55).
                now = day.date(minute: parts.count >= 2 ? parts[0] * 60 + parts[1] : 0, in: zone)
                    .addingTimeInterval(parts.count == 3 ? Double(parts[2]) : 0)
            case "--week":
                guard let day = CalendarDay(rawValue: try value()) else { throw RenderFailure("--week takes 2026-10-19") }
                week = day
            case "--m35-sample": m35Sample = true
            case "--calendar-sample": calendarSample = true
            case "--mc": mc = true
            case "--sweep": sweep = true
            case "--claude": claude = true
            case "--review-layout": reviewLayout = try value()
            case "--size":
                let parts = try value().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw RenderFailure("--size takes 1800x1130") }
                windowSize = CGSize(width: parts[0], height: parts[1])
            case "--panel-width":
                guard let width = Double(try value()) else { throw RenderFailure("--panel-width takes 560") }
                panelWidth = width
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
    /// Calendar draws this item's detail popover inline (`--calendar-sample`).
    var calendarDetail: CalendarDetailPreview?
    /// mc: the practice exam sheet of this course drawn on top (off-screen windows draw no sheet).
    var examSheet: Course.ID?
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
        let size = options.windowSize ?? ParityMode.windowSize
        // `08-course-1800x1130-light.png` for a size other than the mockups'.
        let sizeSuffix = options.windowSize.map { "-\(Int($0.width))x\(Int($0.height))" } ?? ""
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
        // mc: the coach's screens with their actions, previews at the fixed now; never started.
        if let claude = model.claude {
            let fixed = options.now ?? Date()
            model.previewCoach = CoachEngine(services: services, client: claude, now: { fixed })
        }
        model.fixedCalendarWeek = options.week
        if let indexer = model.searchIndexer { _ = try await indexer.catchUp(verifyingText: true) }
        await model.filing?.repairDeckTitles()
        // The search screen as if it had been searched (↩): listed under Recent searches. In the
        // registration domain, so nothing is written to any defaults file.
        var recent = RecentSearches(storage: "")
        recent.record("paravirtualization")
        UserDefaults.standard.register(defaults: [RecentSearches.storageKey: recent.storage])
        // Review's layout as a student left it (the transcript or the thumbnails collapsed).
        if let layout = options.reviewLayout { UserDefaults.standard.register(defaults: ["review.layout": layout]) }
        // The agent's right sidebar as wide as a student left it.
        if let width = options.panelWidth { UserDefaults.standard.register(defaults: ["agent.panel.width": width]) }

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
        if options.calendarSample { try await seedCalendar(services: services) }
        if options.claude {
            model.claudeAvailability = .ready(ClaudeBackendStatus(kind: .claudeCode, version: "2.1.268", subscription: "max"))
        }
        var shots: [RenderShot]
        if options.sweep {
            shots = try await sweepShots(services: services, newestMail: newestMail, now: options.now)
        } else {
            let cc = try ParityMode.course("Data Centers", services: services)
            let (_, dcLecture2) = try ParityMode.lecture("Data Centers", 2, services: services)
            // M6 (`--m6-sample`): mockup 04's open note, the DC L2 note (titled in its first block).
            let dcL2Note = try await services.database.read { db in
                try Note
                    .where { $0.lectureID.eq(dcLecture2.id) && $0.pageNumber.is(nil) && $0.blocksJSON.like("%Virtualization generations%") }
                    .fetchOne(db)?.id
            }
            // ma (`--ma-sample` seed): the agent panel's two sample conversations.
            func appConversation(_ title: String) async throws -> AgentConversation.ID? {
                try await services.database.read { db in
                    try AgentConversation.where { $0.kind.eq(ConversationKind.app) && $0.title.eq(title) }.fetchOne(db)?.id
                }
            }
            let weekendPlan = try await appConversation("Weekend plan")
            let qemu = try await appConversation("QEMU on the M3")
            func panel(_ mode: AgentPanelLaunch.Mode, _ conversation: AgentConversation.ID?, exchanges: Range<Int>? = nil) -> AgentPanelLaunch {
                AgentPanelLaunch(mode: mode, conversationID: conversation, exchanges: exchanges, now: options.now)
            }
            shots = [
                RenderShot(name: "01-today", window: .main(ParityMode.Launch(selection: .today))),
                RenderShot(name: "02-live", window: .live),
                // 37:27, the mockup's moment: slide 16 holds the playhead, so Follow is on.
                RenderShot(name: "03-review", window: .main(ParityMode.Launch(
                    selection: .lecture(dcLecture2.id),
                    reviewTarget: (dcLecture2.id, ReviewTarget(page: 16, time: 2247, request: UUID()))
                ))),
                RenderShot(name: "06-calendar", window: .main(ParityMode.Launch(selection: .calendar))),
                // `--calendar-sample`: a detail popover drawn inline (off-screen windows draw none).
                RenderShot(name: "06-calendar-session", window: .main(ParityMode.Launch(selection: .calendar)), calendarDetail: .session),
                RenderShot(name: "06-calendar-exam", window: .main(ParityMode.Launch(selection: .calendar)), calendarDetail: .exam),
                RenderShot(name: "07-search", window: .main(ParityMode.Launch(selection: .search, query: "paravirtualization"))),
                // Mockup 05: the Inbox, its newest message selected.
                RenderShot(name: "05-mail", window: .main(ParityMode.Launch(selection: .mailScope(.inbox), mailSelection: newestMail))),
                // ma (with `--m35-sample` on a copy seeded by `tools/parity/seed --ma-sample`): the agent
                // panel, mockup agent-panel-mockups.html §1 (Review), §2–3 (Calendar), §4 (Today's files).
                RenderShot(name: "ma-review", window: .main(ParityMode.Launch(
                    selection: .lecture(dcLecture2.id),
                    reviewTarget: (dcLecture2.id, ReviewTarget(page: 12, time: 29 * 60 + 44, request: UUID())),
                    panel: panel(.compact, weekendPlan, exchanges: 0..<1)
                ))),
                // Opened again (no exchange range): the conversation's latest exchange, never only the
                // title row and the composer.
                RenderShot(name: "ma-review-reopened", window: .main(ParityMode.Launch(
                    selection: .lecture(dcLecture2.id),
                    reviewTarget: (dcLecture2.id, ReviewTarget(page: 12, time: 29 * 60 + 44, request: UUID())),
                    panel: panel(.compact, weekendPlan)
                ))),
                // §2: the same conversation after Go ▸ Calendar (its context line "DC Lecture 2").
                RenderShot(name: "ma-calendar", window: .main(ParityMode.Launch(selection: .calendar, panel: panel(.compact, weekendPlan, exchanges: 0..<1)))),
                RenderShot(name: "ma-calendar-expanded", window: .main(ParityMode.Launch(selection: .calendar, panel: panel(.expanded, weekendPlan)))),
                RenderShot(name: "ma-today-files", window: .main(ParityMode.Launch(selection: .today, panel: panel(.compact, qemu, exchanges: 0..<1)))),
                // The sidebar, Course Settings and the agent's right sidebar together (the window
                // layout of 2026-10-20: no column cut off, Course Settings adapts).
                RenderShot(name: "ma-course-expanded", window: .main(ParityMode.Launch(selection: .courseSettings(cc.id), panel: panel(.expanded, weekendPlan)))),
                RenderShot(name: "ma-mail-expanded", window: .main(ParityMode.Launch(
                    selection: .mailScope(.inbox), mailSelection: newestMail, panel: panel(.expanded, weekendPlan)
                ))),
                RenderShot(name: "ma-review-expanded", window: .main(ParityMode.Launch(
                    selection: .lecture(dcLecture2.id),
                    reviewTarget: (dcLecture2.id, ReviewTarget(page: 12, time: 29 * 60 + 44, request: UUID())),
                    panel: panel(.expanded, weekendPlan)
                ))),
                RenderShot(name: "08-course", window: .main(ParityMode.Launch(selection: .courseSettings(cc.id)))),
                RenderShot(name: "08-course-lectures", window: .main(ParityMode.Launch(selection: .courseLectures(cc.id)))),
                // M6 (on a copy seeded by `tools/parity/seed --m6-sample`): mockup 04, the Notes row's
                // All Notes with the DC L2 note selected. Review's ink on slide 16 shows in `03-review`.
                RenderShot(name: "04-notes", window: .main(ParityMode.Launch(selection: .notes(.all), noteSelection: dcL2Note))),
                RenderShot(name: "10-import", window: .main(ParityMode.Launch(selection: .today))) { model, size in
                    try await ParityMode.importPreview(model: model, services: services, size: size)
                }
            ]
            // CL L1 (36 slides, a 44:42 recording, aligned) where review left off: the sidebar
            // on a lecture's screen, and with `--review-layout` the student's collapsed panes.
            if let (_, clLecture1) = try? ParityMode.lecture("Computational Linguistics", 1, services: services) {
                shots.append(RenderShot(name: "03-review-cl", window: .main(ParityMode.Launch(selection: .lecture(clLecture1.id)))))
            }
            shots += try await mdShots(services: services)
            if options.mc { shots = try mcShots(cc: cc, services: services) }
            if !options.m35Sample || weekendPlan == nil || qemu == nil { shots = shots.filter { !$0.name.hasPrefix("ma-") } }
            if !options.calendarSample { shots = shots.filter { $0.calendarDetail == nil } }
        }
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
                let url = options.output.appending(path: "\(shot.name)\(sizeSuffix)-\(scheme == .dark ? "dark" : "light").png")
                try await draw(shot, scheme: scheme, model: model, size: size, settle: options.settle, to: url)
                print(url.path(percentEncoded: false))
            }
            model.filingCenter?.endPreviewDrag()
            model.filingCenter?.toasts.map(\.id).forEach { model.filingCenter?.dismiss($0) }
        }
    }

    /// `--sweep`: the screens of any library, empty or full, with no sample rows needed (empty
    /// states, the agent panel on its latest conversation and as a New Chat, every course's
    /// Lectures, Slides, Notes and Progress as c0, c1, … in sidebar order).
    static func sweepShots(services: StudyServices, newestMail: MailMessage.ID?, now: Date?) async throws -> [RenderShot] {
        let courses = try await services.database.read { db in try Course.order(by: \.sortOrder).fetchAll(db) }
        let newestNote = try await services.database.read { db in try Note.order { $0.updatedAt.desc() }.fetchOne(db)?.id }
        let newestConversation = try await services.database.read { db in
            try AgentConversation.where { $0.kind.eq(ConversationKind.app) }.order { $0.updatedAt.desc() }.fetchOne(db)?.id
        }
        func screen(_ item: SidebarItem, panel: AgentPanelLaunch = AgentPanelLaunch()) -> RenderShot.Window {
            .main(ParityMode.Launch(selection: item, panel: panel))
        }
        func panel(_ mode: AgentPanelLaunch.Mode, _ conversation: AgentConversation.ID?) -> AgentPanelLaunch {
            AgentPanelLaunch(mode: mode, conversationID: conversation, newChat: conversation == nil, now: now)
        }
        var shots = [
            RenderShot(name: "today", window: screen(.today)),
            RenderShot(name: "calendar", window: screen(.calendar)),
            RenderShot(name: "mail", window: screen(.mailScope(.inbox))),
            RenderShot(name: "mail-selected", window: .main(ParityMode.Launch(selection: .mailScope(.inbox), mailSelection: newestMail))),
            RenderShot(name: "notes", window: screen(.notes(.all))),
            RenderShot(name: "notes-selected", window: .main(ParityMode.Launch(selection: .notes(.all), noteSelection: newestNote))),
            RenderShot(name: "study", window: screen(.study)),
            RenderShot(name: "panel-compact-new", window: screen(.today, panel: panel(.compact, nil))),
            RenderShot(name: "panel-compact-latest", window: screen(.mailScope(.inbox), panel: panel(.compact, newestConversation))),
            RenderShot(name: "panel-expanded-latest", window: screen(.calendar, panel: panel(.expanded, newestConversation)))
        ]
        for (index, course) in courses.enumerated() {
            shots += [
                RenderShot(name: "c\(index)-lectures", window: screen(.courseLectures(course.id))),
                RenderShot(name: "c\(index)-slides", window: screen(.courseSlides(course.id))),
                RenderShot(name: "c\(index)-notes", window: screen(.courseNotes(course.id))),
                RenderShot(name: "c\(index)-progress", window: screen(.courseProgress(course.id)))
            ]
        }
        return shots
    }

    /// md: the Documents screen and Search's Documents group (plan-docs §6 "Renders"), or the empty
    /// Documents screen on a library without documents.
    static func mdShots(services: StudyServices) async throws -> [RenderShot] {
        let count = try await services.database.read { db in try StudyDocument.all.fetchCount(db) }
        guard count > 0 else {
            return [RenderShot(name: "md-documents-empty", window: .main(ParityMode.Launch(selection: .documents)))]
        }
        func documents(_ title: String) -> RenderShot.Window {
            .main(ParityMode.Launch(selection: .documents, documentSelection: try? ParityMode.document(title, services: services).id))
        }
        return [
            RenderShot(name: "md-documents", window: documents("Modulhandbuch M.Sc. Informatik")),
            RenderShot(name: "md-documents-cv", window: documents("Curriculum Vitae")),
            RenderShot(name: "md-documents-pending", window: documents("Pruefungsamt_Hinweis_Anmeldung")),
            RenderShot(name: "md-search", window: .main(ParityMode.Launch(selection: .search, query: "Prüfung")))
        ]
    }

    /// mc: the study coach's screens (mockups 11–19, 16 is M7's iPhone) the library has.
    static func mcShots(cc: Course, services: StudyServices) throws -> [RenderShot] {
        func screen(_ selection: SidebarItem) -> RenderShot.Window { .main(ParityMode.Launch(selection: selection)) }
        var shots = [
            RenderShot(name: "11-today-plan", window: screen(.today)),
            RenderShot(name: "12-today-travel", window: screen(.today)),
            RenderShot(name: "13-study", window: screen(.study)),
            RenderShot(name: "14-course-progress", window: screen(.courseProgress(cc.id))),
            RenderShot(name: "17-practice-exam-start", window: screen(.courseProgress(cc.id)), examSheet: cc.id)
        ]
        for (kind, question, name) in [(StudySessionKind.round, 4, "15-quiz-4"), (.round, 7, "15-quiz-7"), (.exam, 2, "18-practice-exam-2"), (.exam, 8, "18-practice-exam-8")] {
            if let session = try? ParityMode.practiceSession(kind, question: question, services: services) {
                shots.append(RenderShot(name: name, window: screen(.practice(session.id))))
            }
        }
        if let results = try? ParityMode.practiceResults(cc, services: services) {
            shots.append(RenderShot(name: "19-practice-exam-results", window: screen(.practiceResults(results.id, course: cc.id))))
        }
        return shots
    }

    /// M3.5's sample rows in the clone: the second-newest inbox mail asks the student something
    /// (`needs_reply`), and an open undated task. Synthetic text; no model call.
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
    }

    /// `--calendar-sample` rows in the clone: an exam review and an exam as a timetable import
    /// writes them (an item added on its own, its source the file with the description and date),
    /// and the study pass's counts for DC Lecture 2. Synthetic text; no model call.
    static func seedCalendar(services: StudyServices) async throws {
        let berlin = TimeZone(identifier: "Europe/Lisbon") ?? .current
        let cl = try ParityMode.course("Computational Linguistics", services: services)
        let cc = try ParityMode.course("Data Centers", services: services)
        let samples: [(TrackedItem, file: String, quote: String)] = [
            (TrackedItem(
                courseID: cl.id, kind: .event, title: "Computational Linguistics exam review", details: "Room 204",
                dueAt: CalendarDay(year: 2026, month: 10, day: 20).date(minute: 14 * 60, in: berlin),
                room: "B2-0204 (Room 204) Sample Street 3, Seminar Building (S | 02)", inCalendar: true
            ), "timetable (7).ics", "Computational Linguistics - Klausureinsicht · 19.10.2026 11:00"),
            (TrackedItem(
                courseID: cc.id, kind: .exam, title: "Data Centers exam", details: "Room 102 / Hall A",
                dueAt: CalendarDay(year: 2026, month: 10, day: 23).date(minute: 9 * 60, in: berlin),
                room: "B1-0102 (Room 102) Sample Street 1, Lecture Building (L | 01) / B0-0001 (Hall A) Example Road 2, Main Hall (M | 02)",
                inCalendar: true
            ), "timetable13.ics", "Klausurtermin 1 · 23.10.2026 09:00")
        ]
        for (item, file, quote) in samples {
            let saved = try await services.records.save(item)
            _ = try await services.records.save(TrackedItemSource(
                trackedItemID: saved.id, kind: .timetable, rfcMessageID: file, quote: quote, calendarAdded: true
            ))
        }
        let (_, lecture) = try ParityMode.lecture("Data Centers", 2, services: services)
        let highlights = (1...5).map { index in
            Annotation(lectureID: lecture.id, layer: .professor, kind: .highlight, body: "Sample highlight \(index)")
        }
        let saidInClass = (1...3).map { index in
            Annotation(lectureID: lecture.id, layer: .ai, kind: .notOnSlides, body: "Sample said in class \(index)")
        }
        _ = try await services.records.save(highlights + saidInClass)
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
                    mailSelection: launch.mailSelection, noteSelection: launch.noteSelection,
                    documentSelection: launch.documentSelection, documentPage: launch.documentPage,
                    panel: launch.panel
                )
                .environment(\.calendarDetailPreview, shot.calendarDetail)
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
        // The columns' minimums did not fit the window: it grew, or the content is wider than the
        // window (laid out centred, cut off at both edges).
        let drawn = host.bounds.size
        if abs(drawn.width - size.width) > 0.5 || abs(drawn.height - size.height) > 0.5 {
            FileHandle.standardError.write(Data("parity-render: \(shot.name) drew at \(Int(drawn.width))×\(Int(drawn.height)), not \(Int(size.width))×\(Int(size.height))\n".utf8))
        }
        let minimum = window.contentMinSize.width
        if minimum > drawn.width + 0.5 {
            FileHandle.standardError.write(Data("parity-render: \(shot.name) needs \(Int(minimum)) pt, wider than its \(Int(drawn.width)) pt window\n".utf8))
        }
        guard var png = SnapshotRunner.composite(frame) else { throw RenderFailure("\(shot.name): nothing drawn") }
        if case .main(let launch) = shot.window, launch.panel.mode == .compact {
            png = try await overlayCompactPanel(on: png, launch: launch, scheme: scheme, model: model, windowSize: frame.bounds.size, settle: settle)
        }
        if let course = shot.examSheet {
            png = try await overlaySheet(on: png, course: course, scheme: scheme, model: model, windowSize: frame.bounds.size, settle: settle)
        }
        try png.write(to: url)
    }

    /// The compact agent panel floats over the columns, but the composite draws the columns'
    /// hosting views after the window's own (where the panel's surface, title row and composer
    /// are): the panel is drawn again on top from its stand-alone form (`AgentPanelSnapshot`, the
    /// same rows), unmoved, 12 pt from the window's trailing and bottom edges.
    static func overlayCompactPanel(
        on png: Data, launch: ParityMode.Launch, scheme: ColorScheme, model: AppModel, windowSize: CGSize, settle: Duration
    ) async throws -> Data {
        // Room for the panel's shadow (radius 20, 12 down).
        let pad: CGFloat = 40
        let margin: CGFloat = 12
        var shown = panelContext(launch)
        if let id = shown.lectureID { shown.courseID = try await model.services?.records.fetch(Lecture.self, id: id)?.courseID }
        let panel = AgentPanelSnapshot(style: .compact, context: shown, launch: launch.panel, windowHeight: windowSize.height)
            .environment(\.agentPanelActions, model.agentPanelActions)
            .padding(pad)
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 336 + 2 * pad, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: settle)
        // The thread measures itself once its rows are read: fit twice.
        for _ in 0..<2 {
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
        }
        host.display()
        guard let piece = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let base = NSBitmapImageRep(data: png),
              let canvas = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else { return png }
        // In points (the context takes the rep's size when it is made).
        canvas.size = windowSize
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return png }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: piece)
        }
        let size = host.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        base.draw(in: CGRect(origin: .zero, size: windowSize))
        // Bottom-left origin: the panel's trailing edge at width - 12, its bottom 12 pt up.
        let rect = CGRect(x: windowSize.width - margin - size.width + pad, y: margin - pad, width: size.width, height: size.height)
        piece.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:]) ?? png
    }

    /// mc (mockup 17): the practice exam sheet as macOS presents it, 404 pt wide, centred, 60 pt
    /// below the window's top, on the window's background with its 20 pt corners and shadow.
    static func overlaySheet(
        on png: Data, course: Course.ID, scheme: ColorScheme, model: AppModel, windowSize: CGSize, settle: Duration
    ) async throws -> Data {
        let pad: CGFloat = 40
        let sheet = PracticeExamSheet(courseID: course, now: model.fixedNow)
            .environment(\.studyCoach, model.screenCoach)
            .environment(\.studyServices, model.services)
            .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
            .padding(pad)
        let host = NSHostingView(rootView: sheet)
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 404 + 2 * pad, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: settle)
        for _ in 0..<2 {
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
        }
        host.display()
        guard let piece = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let base = NSBitmapImageRep(data: png),
              let canvas = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else { return png }
        canvas.size = windowSize
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return png }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: piece)
        }
        let size = host.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        base.draw(in: CGRect(origin: .zero, size: windowSize))
        // Bottom-left origin: the sheet's top 60 pt below the window's top, centred.
        let rect = CGRect(x: ((windowSize.width - size.width) / 2).rounded(), y: windowSize.height - 60 - size.height + pad, width: size.width, height: size.height)
        piece.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:]) ?? png
    }

    /// The panel's prompt for the shot's screen (as `RootView` builds it, with Review's slide).
    static func panelContext(_ launch: ParityMode.Launch) -> AgentContext {
        switch launch.selection {
        case .today: .today
        case .calendar: AgentContext(screen: .calendar)
        case .lecture(let id): AgentContext(screen: .lecture, lectureID: id, page: launch.reviewTarget?.target.page)
        default: AgentContext(screen: .other)
        }
    }
}
