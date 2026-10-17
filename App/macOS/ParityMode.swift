#if DEBUG
import AppKit
import Capture
import CaptureUI
import Filing
import FilingUI
import StudyCore
import StudyUI
import SwiftUI

/// Debug builds only: opens the app on one screen of a throwaway library, in a fixed window, so
/// the real window can be captured and compared with the approved mockups (`tools/parity/shoot`).
///
///     StudyPortal.app/Contents/MacOS/StudyPortal \
///         -StudyPortalDataRoot <library copy> -StudyPortalRoute <route> \
///         [-StudyPortalAppearance light|dark] [-StudyPortalReadyMarker <file>] [-StudyPortalSettle <seconds>] \
///         -ApplePersistenceIgnoreState YES
///
/// Routes: `today`; `course/<name>` and `course/<name>/settings` (a course's name or short name);
/// `lecture/<course>/<number>?slide=N&t=SECONDS`; `search?q=TEXT`;
/// `live-preview/<course>/<lecture number>?slide=N` (the live lecture window in a static
/// recording state: running timer, a fixed input level, the lecture's own captions and slide
/// stamps up to that slide; nothing is recorded); `import-preview` (Today with the drop HUD for a
/// deck of the next lecture and the toast of the latest recording filed). Path parts may be
/// percent-encoded.
///
/// The library comes from `-StudyPortalDataRoot` (or `STUDYPORTAL_DATA_ROOT`); without either,
/// or pointed at the real library, the app opens nothing. Nothing runs in the background (no
/// transcription, no calendar, no first-launch courses), the Keychain is not read, the window is
/// 1440×900 points and nothing is restored. Once the routed screen has rendered, the marker file
/// gets `{"pid", "windowNumber", "route", "active"}` (or `{"error"}`) as JSON; `active` is false
/// when the app could not become the active app (the window then draws as inactive).
@MainActor
enum ParityMode {
    struct Options {
        /// Nil for a route that could not be read (reported through the marker).
        var route: Route?
        var routeText: String
        var dataRoot: URL?
        var appearance: NSAppearance.Name?
        var readyMarker: URL?
        var settle: Duration
    }

    enum Route: Equatable {
        case today
        case course(name: String)
        case lecture(course: String, number: Int, slide: Int?, time: Double?)
        case search(String)
        case livePreview(course: String, number: Int, slide: Int?)
        case importPreview
    }

    enum WindowRole: Hashable {
        case main
        case live
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// What the main window opens on.
    struct Launch {
        var selection: SidebarItem
        var query = ""
        var reviewTarget: (lectureID: Lecture.ID, target: ReviewTarget)?
    }

    static let windowSize = CGSize(width: 1440, height: 900)
    /// A deck dragged in `import-preview` is not in the library; its size is sample content.
    static let previewDeckPages = 58
    static let previewInput = "MacBook Pro Microphone"

    /// Nil unless the app was launched with a parity argument.
    static let options: Options? = parse(CommandLine.arguments)

    private static var windows: [WindowRole: NSWindow] = [:]
    private static var didRun = false
    private static var didWriteMarker = false

    // MARK: - Arguments

    static func parse(_ arguments: [String]) -> Options? {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument.hasPrefix("-StudyPortal"), arguments.index(after: index) < arguments.endIndex {
                values[String(argument.dropFirst())] = arguments[arguments.index(after: index)]
                index = arguments.index(index, offsetBy: 2)
            } else {
                index = arguments.index(after: index)
            }
        }
        let keys = ["StudyPortalRoute", "StudyPortalDataRoot", "StudyPortalAppearance", "StudyPortalReadyMarker", "StudyPortalSettle"]
        guard keys.contains(where: { values[$0] != nil }) else { return nil }
        let text = values["StudyPortalRoute"] ?? "today"
        var options = Options(
            route: Route(text),
            routeText: text,
            dataRoot: values["StudyPortalDataRoot"].map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL },
            appearance: nil,
            readyMarker: values["StudyPortalReadyMarker"].map { URL(filePath: $0) },
            settle: .seconds(values["StudyPortalSettle"].flatMap(Double.init) ?? 2.5)
        )
        switch values["StudyPortalAppearance"]?.lowercased() {
        case "dark": options.appearance = .darkAqua
        case "light": options.appearance = .aqua
        default: break
        }
        return options
    }

    /// The library to open: never the real one.
    static func services(_ options: Options) throws -> StudyServices {
        let environment = ProcessInfo.processInfo.environment[AppPaths.rootOverrideVariable]
        guard let root = options.dataRoot ?? environment.flatMap({ $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory) : nil }) else {
            throw Failure("Parity mode needs -StudyPortalDataRoot <library copy>")
        }
        let real = try AppPaths.live(environment: [:]).root.standardizedFileURL.resolvingSymlinksInPath()
        let chosen = root.standardizedFileURL.resolvingSymlinksInPath()
        if chosen.path(percentEncoded: false).hasPrefix(real.path(percentEncoded: false)) {
            throw Failure("Parity mode never opens the real library (\(real.path(percentEncoded: false)))")
        }
        let paths = AppPaths(root: chosen)
        try paths.createDirectories()
        return StudyServices(
            paths: paths,
            database: try StudyDatabase.open(at: paths.database),
            blobs: BlobStore(root: paths.blobs),
            secrets: InMemorySecretStore()
        )
    }

    /// Before any window exists: the appearance. (`tools/parity/shoot` runs a copy of the app as
    /// com.example.studyportal.parity and clears its defaults before each launch, so no window
    /// frame or column width is remembered from an earlier shot.)
    static func prepareApp() {
        if let appearance = options?.appearance {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
        }
    }

    // MARK: - Windows

    static func register(_ window: NSWindow, role: WindowRole) {
        guard options != nil, windows[role] !== window else { return }
        windows[role] = window
    }

    private static func window(_ role: WindowRole, timeout: Duration = .seconds(20)) async throws -> NSWindow {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let window = windows[role] { return window }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure("No \(role) window")
    }

    /// 1440×900 points, centred below the menu bar, nothing remembered or restored.
    private static func configure(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        window.isRestorable = false
        window.tabbingMode = .disallowed
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: windowSize)
        let origin = CGPoint(x: (visible.midX - windowSize.width / 2).rounded(), y: visible.maxY - windowSize.height)
        window.setFrame(CGRect(origin: origin, size: windowSize), display: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Run

    /// Opens the routed screen, lets it settle and writes the ready marker.
    static func run(model: AppModel, openWindow: OpenWindowAction, show: (Launch) -> Void) async {
        guard let options, !didRun else { return }
        didRun = true
        do {
            guard let services = model.services else { throw Failure(model.launchError ?? "Library unavailable") }
            guard let route = options.route else { throw Failure("Unknown route \(options.routeText)") }
            let main = try await window(.main)
            configure(main)
            NSApp.activate()
            // What a launch does to a library before the window shows it.
            if let indexer = model.searchIndexer { _ = try await indexer.catchUp() }
            await model.filing?.repairDeckTitles()

            var shown = main
            switch route {
            case .today:
                show(Launch(selection: .today))
            case .course(let name):
                // Course Settings is the course's screen.
                show(Launch(selection: .course(try course(name, services: services).id)))
            case .lecture(let courseName, let number, let slide, let time):
                let (_, lecture) = try lecture(courseName, number, services: services)
                let target = ReviewTarget(page: slide, time: time, request: UUID())
                show(Launch(selection: .lecture(lecture.id), reviewTarget: (lecture.id, target)))
            case .search(let text):
                show(Launch(selection: .search, query: text))
            case .livePreview(let courseName, let number, let slide):
                show(Launch(selection: .today))
                let capture = try await livePreview(courseName, number, slide: slide, services: services)
                model.showPreviewCapture(capture)
                openWindow(id: LiveLectureScene.id)
                let live = try await window(.live)
                configure(live)
                main.orderOut(nil)
                shown = live
            case .importPreview:
                show(Launch(selection: .today))
                // The drop area measures itself first (the HUD keeps clear of its edges).
                try await Task.sleep(for: .seconds(1))
                try await importPreview(model: model, services: services, size: main.contentView?.bounds.size ?? windowSize)
            }
            try await Task.sleep(for: options.settle)
            let active = await activate(shown)
            shown.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            writeMarker([
                "pid": Int(ProcessInfo.processInfo.processIdentifier), "windowNumber": shown.windowNumber,
                "route": options.routeText, "active": active
            ])
        } catch {
            fail(String(describing: error))
        }
    }

    /// The shot shows the window as key in the active app (coloured window controls, accent
    /// selection), as the mockups do. Cooperative activation is refused while the user works in
    /// another app, so after a few polite requests the app insists (debug builds only).
    private static func activate(_ window: NSWindow) async -> Bool {
        for attempt in 0..<12 {
            if NSApp.isActive, window.isKeyWindow { return true }
            if attempt < 4 {
                NSApp.activate()
            } else {
                (NSApp as any ForcedActivation).activate(ignoringOtherApps: true)
            }
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(250))
        }
        return NSApp.isActive && window.isKeyWindow
    }

    /// Writes `{"error": message}` to the marker (once), so the shooting tool stops waiting.
    static func fail(_ message: String) {
        Log.app.error("Parity: \(message, privacy: .public)")
        writeMarker(["pid": Int(ProcessInfo.processInfo.processIdentifier), "error": message])
    }

    private static func writeMarker(_ object: [String: Any]) {
        guard let url = options?.readyMarker, !didWriteMarker else { return }
        didWriteMarker = true
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("Parity: writing the marker failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lookups

    private static func course(_ name: String, services: StudyServices) throws -> Course {
        let courses = try services.database.read { db in try Course.order { ($0.sortOrder, $0.name) }.fetchAll(db) }
        let wanted = name.lowercased()
        guard let course = courses.first(where: { $0.name.lowercased() == wanted || $0.shortName.lowercased() == wanted }) else {
            throw Failure("No course \(name)")
        }
        return course
    }

    private static func lecture(_ courseName: String, _ number: Int, services: StudyServices) throws -> (Course, Lecture) {
        let course = try course(courseName, services: services)
        let courseID = course.id
        let lectures = try services.database.read { db in try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db) }
        guard let lecture = lectures.first(where: { $0.number == number }) else {
            throw Failure("No lecture \(number) in \(course.name)")
        }
        return (course, lecture)
    }

    // MARK: - Live preview

    /// The lecture's deck on `slide`, `elapsed` a few seconds after the slide came up in its
    /// recording; the slide stamps up to then and the last lines said as captions (the newest
    /// still settling).
    private static func livePreview(_ courseName: String, _ number: Int, slide: Int?, services: StudyServices) async throws -> AppModel.LiveCapture {
        let (course, lecture) = try lecture(courseName, number, services: services)
        let lectures = LectureRepository(store: services.records)
        var deck: Deck?
        if let deckID = try await lectures.spans(lectureID: lecture.id).first?.deckID {
            deck = try await services.records.fetch(Deck.self, id: deckID)
        }
        var pageTexts: [String]?
        if let deck {
            let pages = try await DeckRepository(store: services.records).pages(deckID: deck.id)
            pageTexts = pages.isEmpty ? nil : pages.map(\.text)
        }
        let session = try await LiveLectureSession.openPreview(
            deckURL: deck?.blob.map(services.blobs.url(for:)),
            deckSHA256: deck?.blobSHA256,
            cacheDirectory: services.paths.caches.appending(path: "Slides", directoryHint: .isDirectory),
            pageTexts: pageTexts,
            captionLocale: Locale(identifier: course.language)
        )

        let page = slide ?? 1
        var elapsed: Double = 0
        var stamps: [LiveLectureSession.PreviewStamp] = []
        var captions = CaptionTranscript(localeIdentifier: Locale(identifier: course.language).identifier)
        if let recording = try await RecordingRepository(store: services.records).recordings(lectureID: lecture.id).first {
            let timed = try await lectures.timedSpans(lectureID: lecture.id, recordingID: recording.id)
            let shown = timed.first { ($0.firstPage ?? 0) <= page && page <= ($0.lastPage ?? $0.firstPage ?? 0) }
            elapsed = (shown?.startTime ?? 0) + 13
            stamps = timed.compactMap { span in
                guard let first = span.firstPage, let start = span.startTime, start <= elapsed else { return nil }
                return LiveLectureSession.PreviewStamp(page: first, time: start)
            }
            let said = try await TranscriptRepository(store: services.records).segments(recordingID: recording.id)
                .filter { $0.startTime < elapsed }
                .suffix(4)
            for (index, segment) in said.enumerated() {
                let isLast = index == said.count - 1
                captions.apply(runs: runs(segment, until: isLast ? elapsed : nil), start: segment.startTime, isFinal: !isLast)
            }
        }
        let note = try await NoteRepository(store: services.records)
            .notes(lectureID: lecture.id, deckID: deck?.id, page: page)
            .first.map(\.plainText)
        session.showPreview(
            page: page, elapsed: elapsed, stamps: stamps, captions: captions,
            level: 0.55, inputName: previewInput, note: note
        )
        return AppModel.LiveCapture(session: session, course: course, deck: deck, lectureID: lecture.id, openedAt: lecture.heldAt ?? Date())
    }

    /// Caption runs from a segment's words (unsure words dotted), up to `end` for the line still
    /// being spoken.
    private static func runs(_ segment: TranscriptSegment, until end: Double?) -> [CaptionTranscript.Run] {
        guard let words = segment.words, !words.isEmpty else { return [CaptionTranscript.Run(text: segment.text)] }
        var runs: [CaptionTranscript.Run] = []
        for word in words where end.map({ word.start < $0 }) ?? true {
            let unsure = (word.confidence ?? 1) < 0.3
            let text = (runs.isEmpty ? "" : " ") + word.text
            if let last = runs.last, last.isLowConfidence == unsure {
                runs[runs.count - 1].text += text
            } else {
                runs.append(CaptionTranscript.Run(text: text, isLowConfidence: unsure))
            }
        }
        return runs
    }

    // MARK: - Import preview

    /// The toast of the latest recording filed into a lecture, and the drop HUD for a deck of the
    /// first course's next lecture (a lecture session without a lecture yet).
    private static func importPreview(model: AppModel, services: StudyServices, size: CGSize) async throws {
        guard let center = model.filingCenter, let filing = model.filing else { return }
        let recent = try await FilingRepository(store: services.records).recent(limit: 50)
        if let latest = recent.first(where: { $0.kind == .recording && $0.lectureID != nil }) {
            var duration: Double?
            if let recordingID = latest.recordingID {
                duration = try await services.records.fetch(Recording.self, id: recordingID)?.duration
            }
            center.preview(toast: FilingOutcome(
                url: URL(filePath: latest.fileName), fileName: latest.fileName, kind: latest.kind, status: .filed,
                filing: latest, place: try await filing.place(of: latest), duration: duration
            ))
        }
        if let place = try await nextLecturePlace(services) {
            let name = String(format: "%02d_%@.pdf", place.number ?? 0, place.course.shortName)
            center.preview(
                predictions: [FilingPrediction(
                    url: URL.temporaryDirectory.appending(path: name), fileName: name, kind: .deck, verdict: .file,
                    places: [place], pageCount: previewDeckPages
                )],
                at: CGPoint(x: (size.width * 0.42).rounded(), y: (size.height * 0.36).rounded())
            )
        }
    }

    private static func nextLecturePlace(_ services: StudyServices) async throws -> FilingPlace? {
        let now = Date()
        let (courses, sessions, lectures) = try await services.database.read { db in
            (
                try Course.order { ($0.sortOrder, $0.name) }.fetchAll(db),
                try LectureSession.where { !$0.isCancelled && $0.startsAt.gte(now) }.order(by: \.startsAt).fetchAll(db),
                try Lecture.all.fetchAll(db)
            )
        }
        let filed = Set(lectures.compactMap(\.lectureSessionID))
        for course in courses {
            guard let session = sessions.first(where: { $0.courseID == course.id && $0.kind == .lecture && !filed.contains($0.id) }) else { continue }
            return FilingPlace(
                course: course, sessionID: session.id, sessionKind: session.kind, number: session.number,
                date: session.startsAt, isNewLecture: true, destination: .session(session.id), confidence: 0.92
            )
        }
        return nil
    }
}

/// `NSApplication.activate(ignoringOtherApps:)` without its deprecation warning: parity shots
/// need the app active even while the user works in another app.
private protocol ForcedActivation {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: ForcedActivation {}

extension ParityMode.Route {
    /// `today`, `course/<name>[/settings]`, `lecture/<course>/<n>?slide=N&t=S`, `search?q=TEXT`,
    /// `live-preview/<course>/<n>?slide=N`, `import-preview`.
    init?(_ text: String) {
        let parts = text.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = (parts.first ?? "").split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = item.first else { continue }
                let value = item.count > 1 ? String(item[1]).replacingOccurrences(of: "+", with: " ") : ""
                query[String(key)] = value.removingPercentEncoding ?? value
            }
        }
        switch (path.first, path.count) {
        case ("today", 1):
            self = .today
        case ("course", 2), ("course", 3) where path[2] == "settings":
            self = .course(name: path[1])
        case ("lecture", 3):
            guard let number = Int(path[2]) else { return nil }
            self = .lecture(course: path[1], number: number, slide: query["slide"].flatMap(Int.init), time: query["t"].flatMap(Double.init))
        case ("search", 1):
            self = .search(query["q"] ?? "")
        case ("live-preview", 3):
            guard let number = Int(path[2]) else { return nil }
            self = .livePreview(course: path[1], number: number, slide: query["slide"].flatMap(Int.init))
        case ("import-preview", 1):
            self = .importPreview
        default:
            return nil
        }
    }
}

/// The main window in parity mode: the routed `RootView` once the library is ready.
struct ParityRootView: View {
    let model: AppModel
    @State private var launch: ParityMode.Launch?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let launch {
                RootView(selection: launch.selection, query: launch.query, reviewTarget: launch.reviewTarget)
                    .environment(model)
            } else {
                Color.clear
            }
        }
        .background { ParityWindowReader(role: .main) }
        .task {
            await ParityMode.run(model: model, openWindow: openWindow) { launch = $0 }
        }
    }
}

/// Hands the window it is in to `ParityMode`.
struct ParityWindowReader: NSViewRepresentable {
    let role: ParityMode.WindowRole

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(role: role)
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let role: ParityMode.WindowRole

        init(role: ParityMode.WindowRole) {
            self.role = role
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            return nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { ParityMode.register(window, role: role) }
        }
    }
}
#endif
