import CalendarSync
import Capture
import ClaudeKit
import Courses
import Filing
import FilingUI
import Foundation
import Mail
import MailIntelligence
import MailUI
import Observation
import Processing
import Search
import StudyCore
import StudyUI
import Transcription
#if os(macOS)
import AppKit
#endif

/// App-wide state and the services wired up at launch. Views read it from the environment.
@Observable
final class AppModel {
    /// Nil only if the library could not be opened; `launchError` then says why.
    let services: StudyServices?
    let launchError: String?
    /// Runs lecture jobs (transcribe → align) in the background; state lives in `job` rows.
    let processor: LectureProcessor?
    /// Smart import: files dropped files to their course and lecture (Undo, Change).
    let filing: FilingService?
    /// The main window's drop HUD, toasts, change sheet and File ▸ Import… panel.
    let filingCenter: FilingCenter?
    /// Mirrors lecture sessions into the "Study Portal" calendar. Mac only until the library
    /// syncs between devices (M7): another device's session ids differ, and each device's orphan
    /// cleanup would delete the other's events.
    let calendarMirror: CalendarMirror?
    /// Keeps the keyword search index in step with transcripts, slides and notes.
    let searchIndexer: SearchIndexer?
    /// Claude for mail routing, extraction and reply drafts: the key is read from the Keychain at
    /// each call, every call is logged to `api_call`. Without a key nothing is sent.
    let claude: ClaudeClient?
    /// Mail intelligence: routes by rules always, indexes mail for search, and runs the model
    /// steps (routing beyond rules, extraction, drafts) only once an API key is saved.
    let mailPipeline: MailPipeline?
    #if os(macOS)
    /// IMAP sync of the uni account (INBOX IDLE, a pass every 5 minutes and on wake). Mac only
    /// until the library syncs between devices, like the calendar mirror.
    let mailEngine: MailSyncEngine?
    /// SMTP for drafts the student sends (the Send button only).
    let mailSender: MailSender?
    #endif
    /// What the Mail screen and the mail account settings ask the app to do (`\.mailActions`).
    @ObservationIgnored private(set) var mailActions = MailActions()

    /// The lecture being captured, owned here so recording outlives its window.
    private(set) var live: LiveCapture?
    /// The sheet the main window shows.
    var sheet: AppSheet?
    /// iOS/iPadOS: the live lecture covers the screen while true (macOS uses its own window).
    var isLivePresented = false
    /// A failure to show once (opening a deck, a live capture).
    var failure: String?
    /// A fixed "now" for screens that show times relative to today (off-screen renders of the
    /// sample library); nil follows the clock.
    var fixedNow: Date?

    /// Recordings whose transcription just finished (from the processor's observer).
    @ObservationIgnored private let transcribed: AsyncStream<Recording.ID>
    @ObservationIgnored private var didStartBackgroundWork = false
    /// False in unit-test hosts and snapshot mode: nothing runs in the background.
    @ObservationIgnored private let runsBackgroundWork: Bool
    @ObservationIgnored private var spokenContentPass: Task<Void, Never>?
    @ObservationIgnored private var calendarAccessAsked = false
    @ObservationIgnored private var wakeObserver: Task<Void, Never>?

    init(services: StudyServices?, launchError: String? = nil, startsProcessing: Bool = true) {
        self.services = services
        self.launchError = launchError
        let (transcribed, finishedTranscription) = AsyncStream.makeStream(of: Recording.ID.self)
        self.transcribed = transcribed
        runsBackgroundWork = startsProcessing
        var processor: LectureProcessor?
        if startsProcessing, let services, let store = try? WhisperModelStore.shared() {
            let engine = WhisperKitEngine(store: store)
            processor = LectureProcessor(
                services: services, engine: engine,
                onIdle: {
                    // The model holds about 1.5 GB; load it again only for the next job.
                    await engine.decoder.unload()
                },
                observer: { event in
                    if case .finished(let job, _) = event, job.stage == .transcribe, job.state == .succeeded,
                       let recordingID = job.recordingID {
                        finishedTranscription.yield(recordingID)
                    }
                }
            )
        }
        self.processor = processor
        if let services {
            let service = FilingService(
                services: services,
                afterImport: { [weak processor] in await processor?.wake() },
                cancelJobs: { [weak processor] recordingID in try? await processor?.cancel(recordingID: recordingID) }
            )
            filing = service
            filingCenter = FilingCenter(service: service)
            searchIndexer = SearchIndexer(services: services)
            let claude = ClaudeClient.studyPortal(services: services)
            self.claude = claude
            let pipeline = MailPipeline(services: services, client: claude)
            mailPipeline = pipeline
            #if os(macOS)
            calendarMirror = startsProcessing ? CalendarMirror(services: services) : nil
            mailEngine = startsProcessing ? MailSyncEngine(services: services, onNewMail: { _ in await pipeline.wake() }) : nil
            mailSender = startsProcessing ? MailSender(services: services) : nil
            #else
            calendarMirror = nil
            #endif
        } else {
            filing = nil
            filingCenter = nil
            searchIndexer = nil
            calendarMirror = nil
            claude = nil
            mailPipeline = nil
            #if os(macOS)
            mailEngine = nil
            mailSender = nil
            #endif
        }
        filingCenter?.didFile = { [weak self] outcomes in
            // New slides may settle a recording that was transcribed before they came.
            if outcomes.contains(where: { $0.kind == .deck && $0.filing?.lectureID != nil }) {
                self?.filesWereFiled()
            }
        }
        mailActions = makeMailActions()
    }

    static func launch() -> AppModel {
        // Hosting unit tests: an empty in-memory library, nothing started.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return AppModel(services: try? StudyServices.inMemory(), startsProcessing: false)
        }
        #if DEBUG && os(macOS)
        // Rendering snapshots of a library (`SnapshotRunner`): nothing is started.
        if SnapshotRunner.directory != nil {
            return AppModel(services: try? StudyServices.live(), startsProcessing: false)
        }
        // Parity screenshots (`ParityMode`): a throwaway library, nothing is started.
        if let options = ParityMode.options {
            do {
                return AppModel(services: try ParityMode.services(options), startsProcessing: false)
            } catch {
                ParityMode.fail(error.localizedDescription)
                return AppModel(services: nil, launchError: error.localizedDescription, startsProcessing: false)
            }
        }
        #endif
        do {
            let model = AppModel(services: try StudyServices.live())
            // App-lifetime work belongs to the app, not to a window: it runs even when the window
            // closes during launch, and a view's cancelled task never stops it halfway.
            Task { await model.startBackgroundWork() }
            return model
        } catch {
            Log.app.fault("Could not open the library: \(error.localizedDescription, privacy: .public)")
            return AppModel(services: nil, launchError: error.localizedDescription)
        }
    }

    // MARK: - Background work

    /// Runs once per launch (started by `launch()`): creates the student's courses in an empty
    /// library, keeps the search index current, re-queues interrupted jobs, files captures a crash
    /// (or a failed filing) left behind through smart import, names decks stored under their file
    /// name, starts processing, gives unsure recordings their look by what was said, and brings
    /// the calendar up to date. Only the processing steps need the transcription engine.
    func startBackgroundWork() async {
        guard runsBackgroundWork, !didStartBackgroundWork, let services else { return }
        didStartBackgroundWork = true
        do {
            let seeded = try await StudentCourses.seedIfEmpty(services: services)
            if !seeded.isEmpty { Log.app.notice("Created \(seeded.count) courses") }
        } catch {
            Log.app.error("Creating the courses failed: \(error.localizedDescription, privacy: .public)")
        }

        if let searchIndexer {
            Task { await searchIndexer.start() }
        }
        let transcribed = transcribed
        Task { [weak self] in
            for await recordingID in transcribed {
                await self?.recordingTranscribed(recordingID)
            }
        }

        // Before anything new is queued: jobs left running by a crash go back in the queue.
        if let processor {
            do {
                try await processor.recover()
            } catch {
                Log.jobs.error("Job recovery failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let filing, let filingCenter {
            // Captures that never reached a filing go through smart import like a Stop: session
            // match, a filing row, a toast with Change….
            let recording = live?.session.package.map { Set([$0.url]) } ?? []
            let pending = await filing.unfiledCaptures(in: services.paths.recordings, excluding: recording)
            if !pending.isEmpty {
                Log.app.notice("Filing \(pending.count) captured lecture(s) left behind")
                await filingCenter.file(pending)
            }
            await filing.repairDeckTitles()
        }
        await processor?.wake()

        if let filing {
            for changed in await filing.fileUnsureRecordingsBySpokenContent() {
                await filingCenter?.refresh(changed)
            }
        }
        startMail(services: services)
        await syncCalendar(full: true)
    }

    /// Mail on the Mac: the pipeline (rules routing and the search index at once, model steps once
    /// a key is saved), drafts a quit left sending checked against Sent (never resent), then the
    /// sync when an account exists; waking from sleep fetches new mail.
    private func startMail(services: StudyServices) {
        #if os(macOS)
        guard let mailPipeline, let mailEngine, let mailSender else { return }
        Task {
            await mailPipeline.start()
        }
        Task {
            guard await Self.hasMailAccount(services) else { return }
            await mailSender.recoverInterruptedSends()
            await mailEngine.start()
        }
        wakeObserver = Task {
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                await mailEngine.syncNow()
                await mailPipeline.wake()
            }
        }
        #endif
    }

    static func hasMailAccount(_ services: StudyServices) async -> Bool {
        ((try? await MailAccountRepository(store: services.records).current()) ?? nil) != nil
    }

    /// A transcript landed: an unsure recording may now be filed by what was said.
    private func recordingTranscribed(_ recordingID: Recording.ID) async {
        guard let filing else { return }
        do {
            if let changed = try await filing.fileBySpokenContent(recordingID: recordingID) {
                await filingCenter?.refresh(changed)
            }
        } catch {
            Log.importer.error("Filing by spoken content failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// After a drop: slides that just arrived may settle a recording that was transcribed before
    /// they were there. Runs once things are quiet.
    func filesWereFiled() {
        guard let filing else { return }
        spokenContentPass?.cancel()
        spokenContentPass = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            for changed in await filing.fileUnsureRecordingsBySpokenContent() {
                await self?.filingCenter?.refresh(changed)
            }
        }
    }

    // MARK: - Calendar

    /// Brings the "Study Portal" calendar in line with the sessions and the deadlines from mail.
    /// Calendar access is asked for only once a course shown in the calendar has a session or a
    /// deadline wants an event; until then nothing is written.
    func syncCalendar(full: Bool = false) async {
        guard let calendarMirror, let services else { return }
        do {
            if !calendarAccessAsked, try await CalendarMirror.hasCalendarWork(services) {
                calendarAccessAsked = true
                _ = try await calendarMirror.requestAccess()
            }
            let report = try await calendarMirror.sync(full: full)
            Log.calendar.info("Calendar sync: \(String(describing: report.outcome), privacy: .public)")
        } catch {
            Log.calendar.error("Calendar sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }


    // MARK: - Live capture

    struct LiveCapture {
        let session: LiveLectureSession
        var course: Course
        let deck: Deck?
        let lectureID: Lecture.ID
        let openedAt: Date
        /// The class being recorded (the session a recording started now is filed to), if the
        /// course has one around now: its number, start and room name the live screen's line.
        var lectureSession: LectureSession?
        /// Where the finished recording goes, once the student changed it on the live screen
        /// (otherwise smart import files it by its course and start time).
        var filingDestination: FilingDestination?
    }

    /// A live lecture that is recording, or not started yet: Record shows it instead of setting
    /// up a new one. A finished one is replaced by the next capture.
    var hasOpenCapture: Bool {
        guard let session = live?.session else { return false }
        return session.isCapturing || session.canStartRecording
    }

    /// Opens a live lecture for `course` showing `deck`. Recording starts from the live screen.
    func openLiveLecture(course: Course, deck: Deck?) async throws {
        guard let services else { return }
        if let live, live.session.isCapturing { return }
        var pages: [DeckPage] = []
        if let deck {
            pages = try await DeckRepository(store: services.records).pages(deckID: deck.id)
        }
        let lectureID = UUID()
        let courseID = course.id
        let session = try await LiveLectureSession.open(
            configuration: .init(
                directory: services.paths.recordings,
                courseID: course.id,
                lectureID: lectureID,
                deckID: deck?.id,
                captionLocale: Locale(identifier: course.language)
            ),
            deckURL: deck?.blob.map(services.blobs.url(for:)),
            deckSHA256: deck?.blobSHA256,
            cacheDirectory: services.paths.caches.appending(path: "Slides", directoryHint: .isDirectory),
            pageTexts: pages.isEmpty ? nil : pages.map(\.text)
        )
        // Filed from here, not from the live screen: Stop and recording failures alike, whether or
        // not the screen is still open.
        session.onFinalized = { [weak self] package in
            self?.fileCapture(package, lectureID: lectureID)
        }
        // Consent can be withdrawn in Course Settings after the lecture was opened.
        session.consentCheck = { [services] in
            (try? await services.records.fetch(Course.self, id: courseID))?.recordsLectures ?? false
        }
        let openedAt = Date()
        let lectureSession = try? await CourseSchedule(services: services).session(forRecordingAt: openedAt, courseID: courseID)
        live = LiveCapture(session: session, course: course, deck: deck, lectureID: lectureID, openedAt: openedAt, lectureSession: lectureSession)
    }

    /// Files a finished capture through smart import (its course from the manifest, its session
    /// by start time, unless the student chose them on the live screen), with a toast, and
    /// queues its processing.
    private func fileCapture(_ package: LecturePackage, lectureID: Lecture.ID) {
        guard let filingCenter else { return }
        let destination = live?.lectureID == lectureID ? live?.filingDestination : nil
        Task {
            await filingCenter.file([package.url], to: destination)
        }
    }

    /// Change on the live screen: the recording belongs to `session` of `course` (or to the
    /// course, when it has no such class).
    func changeLiveFiling(course: Course, session: LectureSession?) {
        guard var capture = live else { return }
        capture.course = course
        capture.lectureSession = session
        capture.filingDestination = session.map { .session($0.id) } ?? .course(course.id)
        live = capture
    }

    #if DEBUG
    /// Debug builds (parity screenshots): shows a preview session as the live lecture. It never
    /// records, so nothing is ever filed from it.
    func showPreviewCapture(_ capture: LiveCapture) {
        live = capture
    }
    #endif

    /// Lets go of the live session once its screen is closed, unless it is starting, recording or
    /// stopping (it must stay owned until the package is final).
    func closeLiveLecture() {
        guard let live, !live.session.isCapturing else { return }
        self.live = nil
    }

    /// Puts a slide PDF into the library for `courseID` (the capture sheet's Choose PDF…).
    func importDeck(at url: URL, courseID: Course.ID) async -> Deck? {
        guard let services else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try await DeckImporter(services: services).importDeck(at: url, courseID: courseID).0
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    /// Records (or withdraws) recording consent for a course.
    func setRecordingConsent(_ granted: Bool, for course: Course) async -> Course? {
        guard let services else { return nil }
        return try? await CourseLibrary(services: services).setRecordingConsent(granted, courseID: course.id)
    }

    func retryProcessing(lectureID: Lecture.ID) {
        let processor = processor
        Task { _ = try? await processor?.retry(lectureID: lectureID) }
    }

    /// Re-aligns one recording at once (a manual "slide starts here").
    nonisolated static func realign(services: StudyServices) -> @Sendable (Lecture.ID, Recording.ID) async throws -> Void {
        let realigner = Realigner(services: services)
        return { lectureID, recordingID in
            _ = try await realigner.realign(lectureID: lectureID, recordingID: recordingID)
        }
    }

    // MARK: - Anthropic API key

    var hasAPIKey: Bool {
        services?.secrets.hasSecret(for: .anthropicAPIKey) ?? false
    }

    func storeAPIKey(_ key: String) throws {
        try services?.secrets.setSecret(key, for: .anthropicAPIKey)
        // Mail waiting for the model (routing beyond rules, extraction) goes now.
        let pipeline = mailPipeline
        Task { await pipeline?.wake() }
    }

    func removeAPIKey() throws {
        try services?.secrets.removeSecret(for: .anthropicAPIKey)
    }
}

// MARK: - Mail actions

extension AppModel {
    /// The Mail screen's effects, each wired to exactly one place (docs/plan-m2.md §7.4): the sync
    /// engine (Get Mail, read, flag, archive, attachments), the sender (Send), the router (a
    /// route correction), the drafter (Reply, Stop), the item actions (Undo, Restore, Add to
    /// Calendar, Discard), the course schedule (Confirm), mail search and the account verifier.
    /// Calendar changes are mirrored at once. Without the sync engine (iOS, snapshots) the
    /// server-side actions stay inert.
    fileprivate func makeMailActions() -> MailActions {
        guard let services, let pipeline = mailPipeline else { return MailActions() }
        let schedule = CourseSchedule(services: services)
        let items = pipeline.actions
        let calendar: @Sendable () async -> Void = { [weak self] in await self?.syncCalendar() }
        var actions = MailActions(
            route: { id, route in _ = try await pipeline.router.correct(id, to: route) },
            draftReply: { id in try await pipeline.drafter.draftReply(to: id) },
            stopDrafting: { id in await pipeline.drafter.stop(id) },
            undo: { id in
                _ = try await items.undo(id)
                await calendar()
            },
            restore: { id in
                _ = try await items.restore(id)
                await calendar()
            },
            addToCalendar: { id in
                _ = try await items.addToCalendar(id)
                await calendar()
            },
            confirmProposal: { id in
                switch try await items.sessionChange(for: id) {
                case .room(let sessionID, let room)?: _ = try await schedule.setRoom(sessionID, room: room)
                case .cancel(let sessionID)?: _ = try await schedule.cancel(sessionID)
                case nil: break
                }
                _ = try await items.settle(id, confirmed: true)
                await calendar()
            },
            discardProposal: { id in _ = try await items.settle(id, confirmed: false) },
            search: { query, scope in try await Self.searchMail(query, in: scope, pipeline: pipeline, services: services) },
            verifyAccount: { account, password in try await MailAccountVerifier().verify(account, password: password) },
            changeFiling: { [weak self] filingID in await self?.filingCenter?.presentChange(filingID) }
        )
        #if os(macOS)
        if let engine = mailEngine, let sender = mailSender {
            actions.syncNow = { await engine.syncNow() }
            actions.setSeen = { ids, seen in try await engine.setSeen(ids, seen) }
            actions.setFlagged = { id, flagged in try await engine.setFlagged(id, flagged) }
            actions.archive = { id in try await engine.archive(id) }
            actions.openAttachment = { id in try await engine.attachmentFile(id) }
            actions.send = { id in try await sender.send(id) }
            // A saved account (or password) logs in again; the first save starts the sync. Not
            // awaited: Save returns at once, the first pass runs in the background.
            actions.accountSaved = { _ in
                Task {
                    await engine.retry()
                    await pipeline.wake()
                }
            }
        }
        #endif
        return actions
    }

    /// The toolbar search on Mail: mail search in the scope; Drafts are matched here (they have no
    /// search chunks).
    nonisolated static func searchMail(
        _ query: String, in scope: MailScope, pipeline: MailPipeline, services: StudyServices
    ) async throws -> [MailMessage.ID] {
        let place: MailSearchScope.Place
        switch scope {
        case .inbox: place = .inbox
        case .course(let id): place = .course(id)
        case .category(let category): place = .category(category)
        case .sent: place = .sent
        case .drafts:
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return [] }
            let open: [MailDraftState] = [.generating, .draft, .failed]
            return try await services.database.read { db in
                try MailDraft.where { $0.state.in(open) }.order { $0.updatedAt.desc() }.fetchAll(db)
                    .filter { draft in
                        [draft.subject, draft.body, draft.to.map(\.address).joined(separator: " "), draft.to.map(\.name).joined(separator: " ")]
                            .contains { $0.localizedStandardContains(needle) }
                    }
                    .map(\.id)
            }
        }
        return try await pipeline.search.search(query, in: MailSearchScope(place)).map(\.messageID)
    }
}

/// What the main window presents as a sheet.
enum AppSheet: Identifiable, Hashable {
    case newCapture
    case newCourse

    var id: Self { self }
}
