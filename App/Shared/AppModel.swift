import CalendarSync
import Capture
import Courses
import Filing
import FilingUI
import Foundation
import Observation
import Processing
import Search
import StudyCore
import Transcription

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

    /// The lecture being captured, owned here so recording outlives its window.
    private(set) var live: LiveCapture?
    /// The sheet the main window shows.
    var sheet: AppSheet?
    /// iOS/iPadOS: the live lecture covers the screen while true (macOS uses its own window).
    var isLivePresented = false
    /// A failure to show once (opening a deck, a live capture).
    var failure: String?

    /// Recordings whose transcription just finished (from the processor's observer).
    @ObservationIgnored private let transcribed: AsyncStream<Recording.ID>
    @ObservationIgnored private var didStartBackgroundWork = false
    /// False in unit-test hosts and snapshot mode: nothing runs in the background.
    @ObservationIgnored private let runsBackgroundWork: Bool
    @ObservationIgnored private var spokenContentPass: Task<Void, Never>?
    @ObservationIgnored private var calendarAccessAsked = false

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
            #if os(macOS)
            calendarMirror = startsProcessing ? CalendarMirror(services: services) : nil
            #else
            calendarMirror = nil
            #endif
        } else {
            filing = nil
            filingCenter = nil
            searchIndexer = nil
            calendarMirror = nil
        }
        filingCenter?.didFile = { [weak self] outcomes in
            // New slides may settle a recording that was transcribed before they came.
            if outcomes.contains(where: { $0.kind == .deck && $0.filing?.lectureID != nil }) {
                self?.filesWereFiled()
            }
        }
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
        await syncCalendar(full: true)
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

    /// Brings the "Study Portal" calendar in line with the sessions. Calendar access is asked for
    /// only once a course shown in the calendar has a session; until then nothing is written.
    func syncCalendar(full: Bool = false) async {
        guard let calendarMirror, let services else { return }
        do {
            if !calendarAccessAsked, try await Self.hasCalendarSessions(services) {
                calendarAccessAsked = true
                _ = try await calendarMirror.requestAccess()
            }
            let report = try await calendarMirror.sync(full: full)
            Log.calendar.info("Calendar sync: \(String(describing: report.outcome), privacy: .public)")
        } catch {
            Log.calendar.error("Calendar sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True when a course shown in the calendar has a session that is not cancelled.
    static func hasCalendarSessions(_ services: StudyServices) async throws -> Bool {
        try await services.database.read { db in
            let visible = try Course.where { $0.showsInCalendar }.fetchAll(db).map(\.id)
            guard !visible.isEmpty else { return false }
            return try LectureSession.where { !$0.isCancelled && $0.courseID.in(visible) }.fetchCount(db) > 0
        }
    }

    // MARK: - Live capture

    struct LiveCapture {
        let session: LiveLectureSession
        let course: Course
        let deck: Deck?
        let lectureID: Lecture.ID
        let openedAt: Date
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
            self?.fileCapture(package)
        }
        // Consent can be withdrawn in Course Settings after the lecture was opened.
        session.consentCheck = { [services] in
            (try? await services.records.fetch(Course.self, id: courseID))?.recordsLectures ?? false
        }
        live = LiveCapture(session: session, course: course, deck: deck, lectureID: lectureID, openedAt: Date())
    }

    /// Files a finished capture through smart import (its course from the manifest, its session
    /// by start time), with a toast, and queues its processing.
    private func fileCapture(_ package: LecturePackage) {
        guard let filingCenter else { return }
        Task {
            await filingCenter.file([package.url])
        }
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
    }

    func removeAPIKey() throws {
        try services?.secrets.removeSecret(for: .anthropicAPIKey)
    }
}

/// What the main window presents as a sheet.
enum AppSheet: Identifiable, Hashable {
    case newCapture
    case newCourse

    var id: Self { self }
}
