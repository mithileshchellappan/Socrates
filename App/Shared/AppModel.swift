import Agent
import AppAgent
import CalendarSync
import CalendarUI
import Capture
import ChatUI
import ClaudeKit
import Coach
import Courses
import Deadlines
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
import StudyPass
import StudyUI
import Sync
import Transcription
#if os(macOS)
import AppKit
import Darwin
import Documents
import DocumentsUI
import EventKit
#endif
#if os(iOS)
import Recorder
import UIKit
#endif

/// App-wide state and the services wired up at launch. Views read it from the environment.
@Observable
final class AppModel {
    /// Nil only if the library could not be opened; `launchError` then says why.
    let services: StudyServices?
    let launchError: String?
    /// Runs lecture jobs (transcribe → align) in the background; state lives in `job` rows. Never
    /// on the iPhone (M7: the Mac transcribes what the phone records).
    let processor: LectureProcessor?
    /// Smart import: files dropped files to their course and lecture (Undo, Change).
    let filing: FilingService?
    /// The main window's drop HUD, toasts, change sheet and File ▸ Import… panel.
    let filingCenter: FilingCenter?
    /// Mirrors lecture sessions into the "Socrates" calendar. Mac only until the library
    /// syncs between devices (M7): another device's session ids differ, and each device's orphan
    /// cleanup would delete the other's events.
    let calendarMirror: CalendarMirror?
    /// Keeps the keyword search index in step with transcripts, slides and notes.
    let searchIndexer: SearchIndexer?
    /// On-device meaning search (M5): embeds what the keyword index holds, in the background.
    /// Mac only; nil on iOS and in snapshot and parity modes (renders search keywords and cached
    /// plans).
    let semanticIndex: SemanticIndex?
    /// Search's "Also searched" (M5): one Haiku call per settled query, cached in `search_plan`.
    /// Mac only, like the semantic index.
    let queryPlanner: HaikuQueryPlanner?
    /// The app's one Claude client (M3.5): the student's Claude Code CLI on the Mac (their
    /// subscription, no API key), unavailable on iOS. Its engine's queue has slots (ma: one
    /// interactive, two background), shared by every caller; every call is logged to `api_call`
    /// (notional cost).
    let claude: ClaudeClient?
    /// Whether Claude Code is installed and signed in (and a usage pause), refreshed at launch and
    /// whenever the app becomes active. Nil until the first check: treated as unavailable.
    var claudeAvailability: ClaudeAvailability?
    /// Mail intelligence: routes by rules always, indexes mail for search, and runs the model
    /// steps (routing beyond rules, triage, drafts) only while Claude Code is available.
    let mailPipeline: MailPipeline?
    #if os(macOS)
    /// IMAP sync of the uni account (INBOX IDLE, a pass every 5 minutes and on wake). Mac only
    /// until the library syncs between devices, like the calendar mirror.
    let mailEngine: MailSyncEngine?
    /// SMTP for drafts the student sends (the Send button only).
    let mailSender: MailSender?
    /// md (docs/plan-docs.md): the document bank (the Documents screen, window drops, the agent's
    /// keep_document and its summary tasks). Mac only: documents never sync. Started (it returns at
    /// once) only where background work runs; renders draw its rows.
    let documentBank: DocumentBank?
    #endif
    /// What the Mail screen and the mail account settings ask the app to do (`\.mailActions`).
    @ObservationIgnored private(set) var mailActions = MailActions()
    /// The deadline & exercise memory (PRD #37): the one write path for tracked items from mail,
    /// lectures, the agent and the student; every change brings the calendar up to date.
    let deadlines: DeadlineMemory?
    /// Claude conversations with a fixed tool set per kind (ma: the app agent's `app` and `task`
    /// conversations). Without Claude Code nothing is sent.
    let agent: AgentRuntime?
    /// The one app agent (ma): the panel's conversation on every screen, the batched triage of new
    /// facts from mail, lectures, timetable imports and the calendar (auto-applied with Undo), the
    /// sub-agent task queue and the reminders. Mac only, and only where background work runs
    /// (never in snapshot and parity modes: renders draw its rows, nothing is sent).
    let appAgent: AppAgent?
    /// Deadlines and announcements from lecture transcripts, with Claude Code.
    let transcriptItems: TranscriptItemPipeline?
    /// The AI study pass (M4): corrections, summaries, said in class, exam hints, further reading,
    /// one unit at a time in the background through Claude Code. Mac only.
    let studyPass: StudyPassPipeline?
    /// The study coach (mc): the plan (`study_block` rows from today to 14 days ahead), rounds and
    /// practice exams with the FSRS scheduler, Opus grading of written answers; its Haiku question
    /// drafting and old exams run in the app agent's task queue. `\.studyCoach` on the window. On
    /// the Mac only where background work runs (renders draw the coach's rows, nothing is sent); on
    /// iOS (M7) `CoachEngine(services:)` without Claude, never started: rounds graded in code.
    let coach: CoachEngine?
    /// M7: iCloud sync of the library (SQLiteData's `SyncEngine`), on the Mac and the iPhone. Nil
    /// unless this build is signed for CloudKit and names its container
    /// (`CloudSyncConfiguration.containerIdentifier()`) and the library is the real one
    /// (`services.syncContainer`): nothing about sync runs otherwise.
    let cloudSync: CloudSync?
    #if os(iOS)
    /// M7, the iPhone: the recorder (mockup 09) and its Live Activity, owned for the app's life so
    /// a recording outlives its screen; `activate()` runs in the App's `init`, before the first
    /// scene, so a Live Activity button that launched the app finds its handler. Its captures stay
    /// in the outbox (never imported on the phone) until shared to the Mac.
    let phoneRecorder: PhoneRecorder?
    #endif
    #if DEBUG
    /// Renders and parity shots (mc): a coach that is never started, so the coach's screens offer
    /// their actions as the mockups draw them (Start, Practice, the sheet's "8 questions · 90
    /// points" read at the render's fixed now). Nothing follows rows, grades or is sent.
    var previewCoach: CoachEngine?
    #endif

    /// What the window's `\.studyCoach` gets: the coach (nil on iOS and in renders without one).
    var screenCoach: (any StudyCoaching)? {
        #if DEBUG
        if let previewCoach { return previewCoach }
        #endif
        return coach
    }
    /// What Today and Calendar ask the app to do (`\.deadlineActions`).
    @ObservationIgnored private(set) var deadlineActions = DeadlineActions()

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
    /// The week Calendar opens on (off-screen renders); nil: the week of "now".
    var fixedCalendarWeek: CalendarDay?
    /// Which calendars Calendar's grid draws (the sidebar's checkboxes), kept per device.
    @ObservationIgnored let calendarVisibility = CalendarVisibility()
    /// Counts changes to the student's calendars (EventKit), so the sidebar's calendar list loads
    /// again (a calendar added, access granted).
    private(set) var calendarStoreRevision = 0

    /// Recordings whose transcription just finished (from the processor's observer).
    @ObservationIgnored private let transcribed: AsyncStream<Recording.ID>
    /// Lectures whose processing step just succeeded (transcribe or align), for the study pass.
    @ObservationIgnored private let processed: AsyncStream<Lecture.ID>
    /// The lecture open in Review, whose study units go first.
    @ObservationIgnored private var reviewedLecture: Lecture.ID?
    @ObservationIgnored private var didStartBackgroundWork = false
    /// False in unit-test hosts and snapshot mode: nothing runs in the background.
    @ObservationIgnored private let runsBackgroundWork: Bool
    @ObservationIgnored private var spokenContentPass: Task<Void, Never>?
    @ObservationIgnored private var calendarAccessAsked = false
    @ObservationIgnored private var wakeObserver: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: Task<Void, Never>?
    @ObservationIgnored private var calendarStoreObserver: Task<Void, Never>?
    @ObservationIgnored private var memoryObserver: Task<Void, Never>?
    /// ma: the full calendar sync after the student's calendars changed (coalesced, at most one a
    /// minute), and when the last one ran.
    @ObservationIgnored private var calendarEditSync: Task<Void, Never>?
    @ObservationIgnored private var lastCalendarEditSync = Date.distantPast
    /// The one calendar sync after deadline writes settle (`deadlinesChanged`).
    @ObservationIgnored private var deadlineSync: Task<Void, Never>?
    /// Lets the services made in `init` call back into the model once it exists.
    @ObservationIgnored private let owner: ModelReference

    init(services: StudyServices?, launchError: String? = nil, startsProcessing: Bool = true) {
        self.services = services
        self.launchError = launchError
        let (transcribed, finishedTranscription) = AsyncStream.makeStream(of: Recording.ID.self)
        self.transcribed = transcribed
        let (processed, finishedProcessing) = AsyncStream.makeStream(of: Lecture.ID.self)
        self.processed = processed
        runsBackgroundWork = startsProcessing
        var processor: LectureProcessor?
        // M7: no transcription on the iPhone (the Mac processes what the phone records).
        if startsProcessing, !Self.isPhone, let services, let store = try? WhisperModelStore.shared() {
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
                    if case .finished(let job, _) = event, job.state == .succeeded, let lectureID = job.lectureID {
                        finishedProcessing.yield(lectureID)
                    }
                }
            )
        }
        self.processor = processor
        if let services {
            let claude = ClaudeClient.studyPortal(services: services)
            self.claude = claude
            // The services exist before the model: they reach it through `owner`.
            let owner = ModelReference()
            // Smart slide filing: a Haiku call decides the decks the heuristics are unsure of
            // (only where background work runs: renders send nothing).
            let advisor: HaikuFilingAdvisor? = startsProcessing ? HaikuFilingAdvisor(client: claude, services: services) : nil
            let service = FilingService(
                services: services,
                afterImport: { [weak processor] in await processor?.wake() },
                cancelJobs: { [weak processor] recordingID in try? await processor?.cancel(recordingID: recordingID) },
                advisor: advisor,
                afterAdvice: { @MainActor filing in await owner.model?.filingCenter?.refresh(filing) }
            )
            filing = service
            filingCenter = FilingCenter(service: service)
            searchIndexer = SearchIndexer(services: services)
            let pipeline = MailPipeline(services: services, client: claude)
            mailPipeline = pipeline
            // Deadline changes reach the calendar through `owner`: one sync after a quiet moment
            // (a triage batch writes several), never one per write.
            let memory = DeadlineMemory(services: services, onChange: { @MainActor in owner.model?.deadlinesChanged() })
            deadlines = memory
            // The agent writes reply drafts through the pipeline's own drafter (the one Mail's Reply
            // uses), so it sees the drafts that one is writing.
            let drafter = pipeline.drafter
            #if os(macOS)
            let semanticIndex = startsProcessing ? SemanticIndex(services: services) : nil
            queryPlanner = startsProcessing ? HaikuQueryPlanner(client: claude, database: services.database) : nil
            #else
            let semanticIndex: SemanticIndex? = nil
            queryPlanner = nil
            #endif
            self.semanticIndex = semanticIndex
            // The agent's lecture search: the same index, no planner (the model writes German and
            // English terms itself).
            let engine = SearchEngine(database: services.database, planner: nil, semantic: semanticIndex)
            // mc: the coach exists before the agent: the plan tools replan through it and the task
            // queue runs its drafting and old exams.
            #if os(macOS)
            let coach = startsProcessing ? CoachEngine(services: services, client: claude) : nil
            #else
            // M7: the phone's coach without Claude (rounds graded in code, written answers left
            // for the Mac); never started: the Mac plans.
            let coach: CoachEngine? = CoachEngine(services: services)
            #endif
            self.coach = coach
            // mr: a deck link, unlink or their Undo queues alignment; the processor runs it.
            let wakeProcessing: @Sendable () async -> Void = { [weak processor] in await processor?.wake() }
            // ma: the `app` conversation (every domain's tools) and the sub-agents' `task`
            // conversations (their tool groups fixed at spawn). md: the document bank's tools.
            #if os(macOS)
            let documentBank = DocumentBank(services: services)
            self.documentBank = documentBank
            let specs = AppAgent.specs(
                services: services, search: engine, drafter: drafter, memory: memory, coach: coach, documents: documentBank,
                wakeProcessing: wakeProcessing
            )
            #else
            let specs = AppAgent.specs(
                services: services, search: engine, drafter: drafter, memory: memory, coach: coach, wakeProcessing: wakeProcessing
            )
            #endif
            let agent = AgentRuntime(
                services: services, client: claude, memory: memory,
                additionalSpecs: specs.additional, conversationSpecs: specs.perConversation
            )
            self.agent = agent
            transcriptItems = TranscriptItemPipeline(services: services, client: claude, memory: memory)
            self.owner = owner
            cloudSync = startsProcessing ? CloudSync(services: services) : nil
            #if os(iOS)
            phoneRecorder = Self.isPhone ? PhoneRecorder(services: services) : nil
            #endif
            #if os(macOS)
            let studyPass = startsProcessing ? StudyPassPipeline(services: services, client: claude) : nil
            self.studyPass = studyPass
            let appAgent = startsProcessing ? AppAgent(
                services: services, client: claude, runtime: agent, memory: memory,
                schedule: CourseSchedule(services: services), studyPass: studyPass, coach: coach, specs: specs,
                filing: service, advisor: advisor, documents: documentBank, wakeProcessing: wakeProcessing
            ) : nil
            self.appAgent = appAgent
            calendarMirror = startsProcessing ? CalendarMirror(services: services) : nil
            // New mail: the pipeline routes and extracts it (its extraction writes the agent's
            // mail events); the agent's triage follows.
            mailEngine = startsProcessing ? MailSyncEngine(services: services, onNewMail: { _ in
                await pipeline.wake()
                await appAgent?.wake()
            }) : nil
            mailSender = startsProcessing ? MailSender(services: services) : nil
            #else
            calendarMirror = nil
            studyPass = nil
            appAgent = nil
            #endif
        } else {
            filing = nil
            filingCenter = nil
            searchIndexer = nil
            semanticIndex = nil
            queryPlanner = nil
            calendarMirror = nil
            claude = nil
            mailPipeline = nil
            deadlines = nil
            agent = nil
            appAgent = nil
            transcriptItems = nil
            studyPass = nil
            coach = nil
            owner = ModelReference()
            cloudSync = nil
            #if os(macOS)
            mailEngine = nil
            mailSender = nil
            documentBank = nil
            #else
            phoneRecorder = nil
            #endif
        }
        filingCenter?.didFile = { [weak self] outcomes in
            // New slides may settle a recording that was transcribed before they came.
            if outcomes.contains(where: { $0.kind == .deck && $0.filing?.lectureID != nil }) {
                self?.filesWereFiled()
            }
        }
        mailActions = makeMailActions()
        deadlineActions = makeDeadlineActions()
        #if os(macOS)
        // md: Word, RTF, Pages, text and images dropped on the window go to the bank ("Added to
        // Documents"; Undo deletes only what the drop added).
        if let bank = documentBank {
            filingCenter?.documents = DocumentDropHandler(
                add: { urls in try await bank.add(urls, by: .user).filter(\.isNew).map(\.document.id) },
                undo: { ids in for id in ids { _ = try? await bank.delete(id) } }
            )
        }
        #endif
        owner.model = self
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
        #if DEBUG && os(iOS)
        // Parity screenshots on the iPhone (`PhoneParity`): a library copy, nothing is started.
        if PhoneParity.route != nil {
            do {
                return AppModel(services: try PhoneParity.services(), startsProcessing: false)
            } catch {
                return AppModel(services: nil, launchError: error.localizedDescription, startsProcessing: false)
            }
        }
        #endif
        do {
            // M7: a build signed for CloudKit opens the library with SQLiteData's sync metadata
            // (nil today: the database opens exactly as before).
            let model = AppModel(services: try StudyServices.live(syncContainer: CloudSyncConfiguration.containerIdentifier()))
            // App-lifetime work belongs to the app, not to a window: it runs even when the window
            // closes during launch, and a view's cancelled task never stops it halfway. It starts
            // after the first frame (DESIGN: cold launch < 1 s), so its library-wide passes never
            // compete with the first screen's reads.
            Task(priority: .utility) {
                try? await Task.sleep(for: .seconds(2))
                await model.startBackgroundWork()
            }
            return model
        } catch {
            Log.app.fault("Could not open the library: \(error.localizedDescription, privacy: .public)")
            return AppModel(services: nil, launchError: error.localizedDescription)
        }
    }

    // MARK: - Background work

    /// Runs once per launch (started by `launch()`): keeps the search index current, re-queues
    /// interrupted jobs, files captures a crash
    /// (or a failed filing) left behind through smart import, names decks stored under their file
    /// name, starts processing, gives unsure recordings their look by what was said, and brings
    /// the calendar up to date. Only the processing steps need the transcription engine.
    func startBackgroundWork() async {
        guard runsBackgroundWork, !didStartBackgroundWork, let services else { return }
        didStartBackgroundWork = true
        // M7: iCloud sync first (only in a build configured for it), so the other device's rows
        // come down before anything is created here.
        if let cloudSync { Task { await cloudSync.start() } }
        observeClaudeAvailability()
        #if os(macOS)
        // md: returns at once (reading resumes after 20 s at utility, file removal after 60 s).
        await documentBank?.start()
        #endif
        // Conversations a quit left running end as failed (only where the agent runs: on a
        // synced iPhone this would fail the conversation the Mac is answering).
        if runsLibraryPasses {
            await agent?.recoverInterrupted()
        }

        if let searchIndexer {
            let semanticIndex = semanticIndex
            Task {
                await searchIndexer.start()
                // Returns at once; embeds in the background, paused while a lecture processes.
                await semanticIndex?.start()
            }
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
            // mr: recordings whose lecture has no slides get one continuation check each (the
            // on-device aligner against the course's recent decks, a deck_link change with Undo).
            do {
                let queued = try await processor.queueContinuationChecks()
                Log.jobs.notice("Continuation checks queued: \(queued)")
            } catch {
                Log.jobs.error("Queueing continuation checks failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if runsLibraryPasses, let filing, let filingCenter {
            // Captures that never reached a filing go through smart import like a Stop: session
            // match, a filing row, a toast with Change….
            let recording = live?.session.package.map { Set([$0.url]) } ?? []
            let pending = await filing.unfiledCaptures(in: services.paths.recordings, excluding: recording)
            if !pending.isEmpty {
                Log.app.notice("Filing \(pending.count) captured lecture(s) left behind")
                await filingCenter.file(pending)
            }
            await filing.repairDeckTitles()
            // Files of decks, lectures and recordings deleted in an earlier session (their Undo
            // is gone with it) once no row uses them; this session's deletions keep theirs.
            await filing.removeDeletedBlobs()
        }
        await processor?.wake()

        if runsLibraryPasses, let filing {
            for changed in await filing.fileUnsureRecordingsBySpokenContent() {
                await filingCenter?.refresh(changed)
            }
        }
        startMail(services: services)
        // Transcripts waiting for extraction are read in the background (only with Claude Code).
        if runsLibraryPasses {
            await transcriptItems?.start()
        }
        // The study pass follows lectures from here on; a finished lecture wakes it at once.
        if let studyPass {
            await studyPass.start()
            let processed = processed
            let appAgent = appAgent
            let coach = coach
            Task {
                for await _ in processed {
                    Task { await studyPass.wake() }
                    // A study pass unit or a transcript may have written an event for triage.
                    Task { await appAgent?.wake() }
                    // mc: new lectures and topics to plan and draft (the coach also follows the
                    // study pass's unit rows on its own).
                    Task { await coach?.wake() }
                }
            }
        }
        await syncCalendar(full: true)
        // ma: after the pipelines (their events wait in `agent_event`): the task queue (re-queues
        // what a quit interrupted), triage and reminders. Fewer background claude processes while
        // the Mac is short of memory.
        if let appAgent {
            await appAgent.start()
            observeMemoryPressure(appAgent)
        }
        // mc: after the agent (the coach queues `question_draft` tasks its queue runs): follows the
        // rows it plans from, replans now and grades the written answers that wait. Mac only (the
        // phone's coach is never started).
        #if os(macOS)
        await coach?.start()
        #endif
    }

    /// M7: the launch passes that rewrite the library's rows (recovering the agent's interrupted
    /// conversations, the filing passes, reading transcripts) run where the library's work is
    /// done: the Mac, and an iPad without sync. The iPhone shows the Mac's rows (synced, they are
    /// the Mac's own: a running conversation there is the Mac answering, not one a quit left).
    private var runsLibraryPasses: Bool {
        #if os(macOS)
        true
        #else
        !Self.isPhone && cloudSync == nil
        #endif
    }

    /// M7: the iPhone idiom (its own shell, recorder, no transcription); false on the Mac and iPad.
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// The agent's background claude processes (sub-agents, triage): 1 while the system has less
    /// than 25 % of its memory free (`kern.memorystatus_level`, what `memory_pressure` reports),
    /// else the default 2. Checked every minute; only a change is passed on.
    private func observeMemoryPressure(_ appAgent: AppAgent) {
        #if os(macOS)
        guard memoryObserver == nil else { return }
        memoryObserver = Task.detached(priority: .background) {
            var applied: Int?? = .none
            while !Task.isCancelled {
                var level: Int32 = 100
                var size = MemoryLayout<Int32>.size
                let free = sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? Int(level) : 100
                let limit: Int? = free < 25 ? 1 : nil
                if applied != .some(limit) {
                    applied = .some(limit)
                    await appAgent.setBackgroundLimit(limit)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        #endif
    }

    /// Mail on the Mac: the pipeline (rules routing and the search index at once; triage of new
    /// mail and the 30-day backlog while Claude Code is available), drafts a quit left sending
    /// checked against Sent (never resent), then the sync when an account exists; waking from
    /// sleep fetches new mail.
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

    /// A transcript landed: its deadlines and announcements are read (with Claude Code), and an unsure
    /// recording may now be filed by what was said.
    private func recordingTranscribed(_ recordingID: Recording.ID) async {
        let transcriptItems = transcriptItems
        let appAgent = appAgent
        Task {
            await transcriptItems?.wake()
            await appAgent?.wake()
        }
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

    /// Brings the "Socrates" calendar in line with the sessions and the deadlines from mail.
    /// Calendar access is asked for only once a course shown in the calendar has a session or a
    /// deadline wants an event; until then nothing is written.
    func syncCalendar(full: Bool = false) async {
        guard let calendarMirror, let services else { return }
        do {
            if !calendarAccessAsked, try await CalendarMirror.hasCalendarWork(services) {
                calendarAccessAsked = true
                _ = try await calendarMirror.requestAccess()
                calendarStoreRevision += 1
                observeCalendarStore()
            }
            let report = try await calendarMirror.sync(full: full)
            Log.calendar.info("Calendar sync: \(String(describing: report.outcome), privacy: .public)")
        } catch {
            Log.calendar.error("Calendar sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }


    /// A deadline was written (the memory's `onChange`): the mirror is out of date. One sync
    /// follows about 2 s after the last write, so a triage batch of several items runs one
    /// EventKit pass, not one per item.
    func deadlinesChanged() {
        deadlineSync?.cancel()
        deadlineSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            deadlineSync = nil
            await syncCalendar()
        }
    }

    /// The student's calendars change (another app, iCloud): the sidebar's list loads again.
    private func observeCalendarStore() {
        #if os(macOS)
        guard calendarStoreObserver == nil else { return }
        calendarStoreObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                self?.calendarStoreRevision += 1
                self?.calendarChangedElsewhere()
            }
        }
        #endif
    }

    /// ma: a Socrates event moved or deleted in Calendar.app is found by a full sync only (it
    /// records a `calendar` event for the agent's triage and leaves the student's edit until triage
    /// decides). Coalesced, and at most one a minute: the mirror's own writes post the same
    /// notification, and a full sync after them writes nothing.
    private func calendarChangedElsewhere() {
        guard appAgent != nil, calendarEditSync == nil else { return }
        let wait = max(5, 60 - Date().timeIntervalSince(lastCalendarEditSync))
        calendarEditSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            lastCalendarEditSync = Date()
            calendarEditSync = nil
            await syncCalendar(full: true)
            await appAgent?.wake()
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

    /// Re-aligns one recording at once (a manual "slide starts here"); the study pass then looks
    /// at the lecture again (it waits for the realign burst to settle).
    nonisolated static func realign(services: StudyServices, studyPass: StudyPassPipeline?) -> @Sendable (Lecture.ID, Recording.ID) async throws -> Void {
        let realigner = Realigner(services: services)
        return { lectureID, recordingID in
            _ = try await realigner.realign(lectureID: lectureID, recordingID: recordingID)
            if let studyPass {
                Task { await studyPass.wake() }
            }
        }
    }

    /// A lecture opened in Review (nil: it closed): its study units go first.
    func reviewOpened(_ lectureID: Lecture.ID) {
        reviewedLecture = lectureID
        preferStudyPass(lectureID)
    }

    func reviewClosed(_ lectureID: Lecture.ID) {
        // Another lecture may have opened first (the views swap in either order).
        guard reviewedLecture == lectureID else { return }
        reviewedLecture = nil
        preferStudyPass(nil)
    }

    private func preferStudyPass(_ lectureID: Lecture.ID?) {
        guard let studyPass else { return }
        Task { await studyPass.prefer(lectureID) }
    }

    // MARK: - Claude Code

    /// Checks Claude Code at launch and whenever the app becomes active (it may have been
    /// installed, signed in or out meanwhile), and ends its processes when the app quits.
    private func observeClaudeAvailability() {
        Task { await refreshClaudeAvailability() }
        #if os(macOS)
        activationObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                // The 60 s cache applies: every switch back to the app must not start two CLI probes.
                await self?.refreshClaudeAvailability(force: false)
            }
        }
        // Synchronous, while the app still runs: a tool loop's MCP server lives in the app.
        let studyPass = studyPass
        let semanticIndex = semanticIndex
        let appAgent = appAgent
        let coach = coach
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            // First, synchronously: a task or triage call failing because its process is ended
            // below writes nothing (the task resumes at the next launch, the events stay pending).
            appAgent?.prepareForQuit()
            // mc: the coach stops following rows and grading; answers in flight stay pending.
            if let coach {
                Task { await coach.stop() }
            }
            ClaudeCodeEngine.terminateRunningProcesses()
            // Running tasks keep their rows (re-queued at the next launch); triage and reminders stop.
            if let appAgent {
                Task { await appAgent.stop() }
            }
            // A unit in flight stays pending (nothing is written before its call ends).
            if let studyPass {
                Task { await studyPass.stop() }
            }
            // A batch ends after its current unit; unchanged text is never embedded twice.
            if let semanticIndex {
                Task { await semanticIndex.stop() }
            }
        }
        #endif
    }

    /// Checks Claude Code again (`force`: no cached answer). When it turns ready, the work that
    /// waited for it starts: mail triage with its backlog, transcripts and the study pass.
    func refreshClaudeAvailability(force: Bool = true) async {
        guard let claude else { return }
        let availability = force ? await claude.refreshAvailability() : await claude.availability()
        let wasReady = claudeAvailability?.isReady ?? false
        if availability != claudeAvailability { claudeAvailability = availability }
        guard availability.isReady, !wasReady, runsBackgroundWork else { return }
        let pipeline = mailPipeline
        let transcriptItems = transcriptItems
        let studyPass = studyPass
        let appAgent = appAgent
        let coach = coach
        Task { await pipeline?.wake() }
        Task { await transcriptItems?.wake() }
        Task { await studyPass?.wake() }
        Task { await appAgent?.wake() }
        // mc: written answers that waited for Claude Code are graded.
        Task { await coach?.wake() }
    }

    /// The agent panel's effects (`\.agentPanelActions`), rebuilt when the availability changes:
    /// the panel's messages, Stop, the answer being written, Cancel of a sub-agent task and Undo of
    /// a change row, all through the app agent. Absent without Claude Code and on iOS; in snapshot
    /// and parity modes (no agent) the panel draws its rows and sends nothing.
    var agentPanelActions: AgentPanelActions {
        #if os(macOS)
        guard let availability = claudeAvailability, availability.isReady else { return AgentPanelActions() }
        guard let appAgent else { return AgentPanelActions(isAvailable: true, pausedUntil: availability.status?.pausedUntil) }
        return AgentPanelActions(
            isAvailable: true,
            pausedUntil: availability.status?.pausedUntil,
            send: { text, context, files, conversation in
                do {
                    return try await appAgent.send(text, context: context, attachments: files, to: conversation)
                } catch {
                    // One readable sentence for the panel's notice line, never the error's text.
                    let sentence = AppAgent.readableSendFailure(error)
                        ?? ReadableError.sentence(for: error, otherwise: String(localized: "Not sent"), retrying: false)
                    throw AgentSendFailure(sentence: sentence)
                }
            },
            stop: { id in await appAgent.stop(id) },
            liveReply: { id in
                let source = appAgent.liveReplies(id)
                return AsyncStream { continuation in
                    let task = Task {
                        for await reply in source {
                            continuation.yield(reply.map { ChatLiveReply(afterTurns: $0.afterTurns, text: $0.text, isUnsaved: $0.unsaved) })
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            cancelTask: { id in await appAgent.cancelTask(id) },
            undoChange: { id in try await appAgent.undo(id) },
            retry: { id in
                do {
                    try await appAgent.retry(id)
                } catch {
                    let sentence = ReadableError.sentence(for: error, otherwise: String(localized: "Not sent"), retrying: false)
                    throw AgentSendFailure(sentence: sentence)
                }
            },
            contextLine: { context in
                guard let line = await appAgent.contextLine(for: context) else { return nil }
                return AgentContextLine(glyph: line.glyph, label: line.label)
            }
        )
        #else
        // M7: the phone never runs Claude: a question becomes an `agent_request` row the Mac
        // answers once iCloud sync carries it. Hidden (nothing disabled) while sync is off.
        guard let services else { return AgentPanelActions() }
        return .relay(services: services, isAvailable: cloudSync?.isRunning ?? false)
        #endif
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
        let appAgent = appAgent
        let calendar: @Sendable () async -> Void = { [weak self] in await self?.syncCalendar() }
        var actions = MailActions(
            route: { id, route in _ = try await pipeline.router.correct(id, to: route) },
            draftReply: { id in try await pipeline.drafter.draftReply(to: id) },
            stopDrafting: { id in await pipeline.drafter.stop(id) },
            // Session changes the agent applied go back through its change log, the rest through the
            // deadline memory (`AppAgent.undo(sourceID:)` does both).
            undo: { id in
                if let appAgent {
                    try await appAgent.undo(sourceID: id)
                } else {
                    _ = try await items.undo(id)
                }
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
            changeFiling: { [weak self] filingID in await self?.filingCenter?.presentChange(filingID) },
            // Local only (no server flag): the student says a mail needs no answer.
            setNeedsReply: { id, value in
                let stamp = services.records.currentDate
                try await services.database.write { db in
                    try MailMessage.find(id).update {
                        $0.needsReply = Bool?.some(value)
                        $0.updatedAt = stamp
                    }
                    .execute(db)
                }
            }
        )
        #if os(macOS)
        if let engine = mailEngine, let sender = mailSender {
            actions.syncNow = { await engine.syncNow() }
            actions.setSeen = { ids, seen in try await engine.setSeen(ids, seen) }
            actions.setFlagged = { id, flagged in try await engine.setFlagged(id, flagged) }
            actions.archive = { id in try await engine.archive(id) }
            actions.openAttachment = { id in try await engine.attachmentFile(id) }
            actions.send = { id in try await sender.send(id) }
            actions.sendAgain = { id in try await sender.send(id, confirmingResend: true) }
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

// MARK: - Deadline actions

extension AppModel {
    /// Today's and Calendar's effects, each wired to exactly one place (docs/plan-m3.md §6.4):
    /// Undo, Restore, Mark as Done, Delete and Add to Calendar to the deadline memory (whose
    /// changes sync the calendar); Confirm through the item actions to the course schedule, then
    /// settled; Discard settled; Cancel and Restore Session to the course schedule. Undo goes through
    /// the app agent (session changes it applied through its change log). Calendar's "New deadline"
    /// field is gone (ma): its [+] opens the agent panel.
    fileprivate func makeDeadlineActions() -> DeadlineActions {
        guard let services, let memory = deadlines, let items = mailPipeline?.actions else { return DeadlineActions() }
        let appAgent = appAgent
        let schedule = CourseSchedule(services: services)
        let calendar: @Sendable () async -> Void = { [weak self] in await self?.syncCalendar() }
        return DeadlineActions(
            undo: { id in
                if let appAgent {
                    try await appAgent.undo(sourceID: id)
                } else {
                    _ = try await memory.undo(id)
                }
            },
            restore: { id in _ = try await memory.restore(id) },
            complete: { id in _ = try await memory.complete(id) },
            remove: { id in _ = try await memory.remove(id) },
            addToCalendar: { id in _ = try await memory.addToCalendar(id) },
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
            cancelSession: { id in
                _ = try await schedule.cancel(id)
                await calendar()
            },
            restoreSession: { id in
                _ = try await schedule.restore(id)
                await calendar()
            }
        )
    }
}

/// The app model as seen from services created before it (the deadline memory's `onChange`).
@MainActor
final class ModelReference {
    weak var model: AppModel?
}

/// What the main window presents as a sheet.
enum AppSheet: Identifiable, Hashable {
    case newCapture
    case newCourse

    var id: Self { self }
}
