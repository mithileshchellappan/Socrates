import Foundation
import Observation

/// One live lecture: the deck on screen, the recording, slide stamps, flags and quick notes.
///
/// Navigation before recording starts moves the deck without stamping (e.g. to start at
/// slide 13). While recording, every slide change and flag is stamped the moment the action
/// arrives: host time first, then mapped onto the recording clock. Everything is written to a
/// lecture package on disk as it happens; nothing here touches the database.
///
/// The iPhone can pause (`pause()`, `resume()`): no audio is captured meanwhile, nothing is
/// stamped, and the recording goes on into the same package after the gap (`pause` and `resume`
/// events; the clock keeps real time, so the gap is silence on the Mac). The Mac never pauses.
///
/// One session records one lecture. The app owns it for as long as it records (it must outlive
/// the view).
@MainActor
@Observable
public final class LiveLectureSession {
    public enum Phase: Sendable, Equatable {
        /// Not recording yet; navigation does not stamp.
        case ready
        case starting
        case recording
        /// iPhone: no audio is captured and nothing is stamped until `resume()`.
        case paused
        case stopping
        case finished
        case failed(Failure)
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Recording consent for the course was withdrawn after the lecture was opened.
        case notConsented
        case microphoneDenied
        case noInputDevice
        /// iOS: a call or another app holds the input.
        case inputBusy
        /// The package or audio could not be written.
        case storage(String)
        case engine(String)
    }

    public struct Configuration: Sendable {
        /// Folder that receives the `<uuid>.lecture` package (`AppPaths.recordings`).
        public var directory: URL
        public var courseID: UUID?
        public var lectureID: UUID?
        /// `Deck.id` of the deck on screen, if it is in the database.
        public var deckID: UUID?
        /// Language for live captions; nil hides captions.
        public var captionLocale: Locale?
        public var format: RecordingFormat
        public var segmentDuration: Duration
        /// 1-based page shown first.
        public var initialPage: Int
        /// iPhone (M7): without a deck, Next and Previous still count slides (from `initialPage`,
        /// never below 1, no upper bound) and the stamps carry those numbers. Off on the Mac, whose
        /// deckless live screen does not count.
        public var countsSlidesWithoutDeck: Bool
        /// What the manifest says the recording is for besides the ids (M7): the course's name and
        /// short name, the class's number and name. The iPhone sets them because its ids are not
        /// the Mac's until sync; the Mac's smart import files a phone capture by them.
        public var assignment: Assignment

        public init(
            directory: URL,
            courseID: UUID? = nil,
            lectureID: UUID? = nil,
            deckID: UUID? = nil,
            captionLocale: Locale? = nil,
            format: RecordingFormat = .standard,
            segmentDuration: Duration = .seconds(300),
            initialPage: Int = 1,
            countsSlidesWithoutDeck: Bool = false,
            assignment: Assignment = Assignment()
        ) {
            self.directory = directory
            self.courseID = courseID
            self.lectureID = lectureID
            self.deckID = deckID
            self.captionLocale = captionLocale
            self.format = format
            self.segmentDuration = segmentDuration
            self.initialPage = initialPage
            self.countsSlidesWithoutDeck = countsSlidesWithoutDeck
            self.assignment = assignment
        }
    }

    /// The names a recording is filed by where its ids are unknown (M7: a phone capture on the
    /// Mac before sync). All optional; written into the manifest.
    public struct Assignment: Sendable, Hashable {
        /// "Data Centers".
        public var courseName: String?
        /// "DC".
        public var courseShortName: String?
        /// The lecture's number when the class is a numbered lecture ("Lecture 2" → 2).
        public var sessionNumber: Int?
        /// What the recorder showed ("DC Lecture 2"): the capture's title in the phone's outbox.
        public var sessionName: String?

        public init(courseName: String? = nil, courseShortName: String? = nil, sessionNumber: Int? = nil, sessionName: String? = nil) {
            self.courseName = courseName
            self.courseShortName = courseShortName
            self.sessionNumber = sessionNumber
            self.sessionName = sessionName
        }
    }

    public let configuration: Configuration
    /// The course and class the recording is for; `reassign` changes them (the iPhone's course
    /// menu, also while it records).
    public private(set) var courseID: UUID?
    public private(set) var lectureID: UUID?
    public private(set) var assignment: Assignment
    public let deck: SlideDeck?
    public let pageCount: Int
    /// Short title per page (index 0 = page 1); empty strings when unknown.
    public let pageTitles: [String]

    public private(set) var phase: Phase = .ready
    /// 1-based page on screen (1 when there is no deck).
    public private(set) var currentPage: Int
    public private(set) var events: [LectureEvent] = []
    /// Quick notes by page.
    public private(set) var notes: [Int: QuickNote] = [:]
    /// Input level for the meter, 0…1.
    public private(set) var level: Float = 0
    public private(set) var inputName: String?
    public private(set) var isInputAvailable = true
    /// Provisional captions; nil while captions are not running.
    public internal(set) var captions: CaptionTranscript?
    /// Wall clock at sample 0.
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var package: LecturePackage?
    /// The recording's audio segments as the capture last reported them, set before the
    /// manifest is written: the manifest on disk lags behind (it is written asynchronously, and a
    /// crash can leave it without the newest segment), so a reader of the live recording asks
    /// this list (`closedThrough`), never the file.
    public private(set) var segments: [AudioSegmentInfo] = []

    /// Called once the package is final: after Stop, or after a recording failure stopped it.
    /// The owner (not the view) sets it to file the capture, so filing never depends on a screen
    /// being open.
    @ObservationIgnored public var onFinalized: (@MainActor (LecturePackage) -> Void)?

    /// Asked right before recording starts (Record button, menu, toolbar): true while recording
    /// consent for the course is recorded. Consent can be withdrawn after the lecture was opened
    /// (Course Settings), so the check at opening is not enough. Nil: no check.
    @ObservationIgnored public var consentCheck: (@MainActor () async -> Bool)?

    @ObservationIgnored private let capture: any AudioCaptureSource
    @ObservationIgnored private let host: HostClock
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var clock: RecordingClock?
    @ObservationIgnored private var writer: LecturePackageWriter?
    @ObservationIgnored private var eventsRevision = 0
    @ObservationIgnored private var notesRevision = 0
    @ObservationIgnored private var liveTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var notesSaveTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prerenderTask: Task<Void, Never>?

    public init(
        configuration: Configuration,
        deck: SlideDeck?,
        pageTitles: [String] = [],
        capture: any AudioCaptureSource = MicrophoneCapture(),
        host: HostClock = .system,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.deck = deck
        self.pageCount = deck?.pageCount ?? 0
        self.pageTitles = pageTitles
        self.capture = capture
        self.host = host
        self.now = now
        self.courseID = configuration.courseID
        self.lectureID = configuration.lectureID
        self.assignment = configuration.assignment
        self.currentPage = deck.map { min(max(1, configuration.initialPage), $0.pageCount) }
            ?? (configuration.countsSlidesWithoutDeck ? max(1, configuration.initialPage) : 1)
        if let deck {
            prerenderTask = Task(priority: .utility) {
                await deck.prerender(widths: [SlideWidth.thumbnail, SlideWidth.display])
            }
            prefetchAround(currentPage)
        }
    }

    isolated deinit {
        prerenderTask?.cancel()
        prefetchTask?.cancel()
        notesSaveTask?.cancel()
        for task in liveTasks { task.cancel() }
    }

    /// Opens the deck off the main actor (hashing, PDF parsing, text extraction) and makes a
    /// session. Pass `pageTexts` when the database already has them (skips extraction).
    public static func open(
        configuration: Configuration,
        deckURL: URL?,
        deckSHA256: String? = nil,
        cacheDirectory: URL,
        pageTexts: [String]? = nil,
        capture: any AudioCaptureSource = MicrophoneCapture()
    ) async throws -> LiveLectureSession {
        let (deck, titles) = try await loadDeck(
            url: deckURL, sha256: deckSHA256, cacheDirectory: cacheDirectory, pageTexts: pageTexts
        )
        return LiveLectureSession(configuration: configuration, deck: deck, pageTitles: titles, capture: capture)
    }

    @concurrent
    nonisolated private static func loadDeck(
        url: URL?, sha256: String?, cacheDirectory: URL, pageTexts: [String]?
    ) async throws -> (SlideDeck?, [String]) {
        guard let url else { return (nil, []) }
        let deck = try SlideDeck(url: url, sha256: sha256, cacheDirectory: cacheDirectory)
        let texts = pageTexts ?? DeckText.extract(from: url)?.pages.map(\.text) ?? []
        return (deck, texts.map { DeckText.title(fromPageText: $0) })
    }

    // MARK: - Derived state

    public var isRecording: Bool { phase == .recording }

    /// Starting, recording, paused or stopping: the session must stay alive.
    public var isCapturing: Bool {
        phase == .starting || phase == .recording || phase == .paused || phase == .stopping
    }

    /// Ready, or a start that failed before anything was recorded (e.g. microphone denied). A
    /// session whose recording failed midway is finished; a new lecture needs a new session.
    public var canStartRecording: Bool {
        switch phase {
        case .ready: true
        case .failed: package == nil
        default: false
        }
    }

    /// Quick notes and flag text can be edited until recording stops. The package is filed into
    /// the library then, so later edits would never reach it.
    public var acceptsNotes: Bool {
        switch phase {
        case .ready, .starting, .recording, .paused: true
        case .failed: package == nil
        case .stopping, .finished: false
        }
    }

    public var hasDeck: Bool { pageCount > 0 }
    /// Slides are tracked and stamped with numbers: a deck is on screen, or the phone counts.
    public var tracksSlides: Bool { hasDeck || configuration.countsSlidesWithoutDeck }
    public var canGoNext: Bool { hasDeck ? currentPage < pageCount : configuration.countsSlidesWithoutDeck }
    public var canGoPrevious: Bool { tracksSlides && currentPage > 1 }
    public var sampleRate: Double { configuration.format.sampleRate }

    /// Slide stamps and flags, oldest first (no stop event).
    public var stamps: [LectureEvent] {
        events.filter { $0.kind.showsSlide || $0.kind == .flag }
    }

    /// The stamp of the slide on screen now (the latest slide stamp).
    public var currentStampID: LectureEvent.ID? {
        events.last { $0.kind.showsSlide }?.id
    }

    public func title(ofPage page: Int) -> String {
        pageTitles.indices.contains(page - 1) ? pageTitles[page - 1] : ""
    }

    /// Seconds on the recording clock of an event.
    public func time(of event: LectureEvent) -> TimeInterval? {
        event.time(sampleRate: sampleRate)
    }

    /// The pauses so far (iPhone); the last one is open while paused.
    public var pauses: RecordingPauses { RecordingPauses(events: events) }

    /// The highest segment sequence whose file is closed (0: none). A closed file never changes
    /// again (every new segment is a new file, opened only after the one before it closed), so
    /// the files up to this one can be copied while the recording goes on. A bound, not a list:
    /// - paused, finished or failed: every segment (a pause closes the open file; after a stop
    ///   every file is closed, also one whose frame count a write failure cleared);
    /// - otherwise the newest when its frame count is known (set only once its file closed),
    ///   else the one before it. A missing frame count never means "still open" on its own.
    public var closedThrough: Int {
        guard let newest = segments.max(by: { $0.sequence < $1.sequence }) else { return 0 }
        switch phase {
        case .paused, .finished, .failed:
            return newest.sequence
        case .ready, .starting, .recording, .stopping:
            return newest.frameCount != nil ? newest.sequence : newest.sequence - 1
        }
    }

    /// Seconds recorded at `date`: wall time since the start without the pauses, frozen once
    /// recording stopped.
    public func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        let end = endedAt ?? date
        return max(0, end.timeIntervalSince(startedAt) - pauses.pausedSeconds(until: end))
    }

    public func note(forPage page: Int) -> String {
        notes[page]?.text ?? ""
    }

    // MARK: - Recording

    /// Asks for the microphone, creates the lecture package and starts recording. On failure
    /// `phase` becomes `.failed` and nothing is left on disk.
    public func start() async {
        guard canStartRecording else { return }
        phase = .starting
        if let consentCheck, await !consentCheck() {
            CaptureLog.capture.notice("Recording not started: no consent for the course")
            phase = .failed(.notConsented)
            return
        }
        guard await capture.requestPermission() else {
            phase = .failed(.microphoneDenied)
            return
        }

        let id = UUID()
        let package: LecturePackage
        let writer: LecturePackageWriter
        do {
            package = try LecturePackage.create(in: configuration.directory, id: id)
            writer = try LecturePackageWriter(package: package, manifest: makeManifest(id: id))
        } catch {
            CaptureLog.capture.error("Could not create lecture package: \(error.localizedDescription, privacy: .public)")
            phase = .failed(.storage(error.localizedDescription))
            return
        }

        let statusUpdates = capture.statusUpdates()
        let start: CaptureStart
        do {
            start = try await capture.start(
                in: package.audioDirectory,
                format: configuration.format,
                segmentDuration: configuration.segmentDuration
            )
        } catch {
            try? FileManager.default.removeItem(at: package.url)
            phase = .failed(Self.failure(from: error))
            return
        }

        self.package = package
        self.writer = writer
        self.segments = []
        self.clock = start.clock
        self.startedAt = start.startedAt
        self.inputName = start.device?.name
        self.isInputAvailable = true
        // Stamp from here on, before any suspension point, so no key press goes unstamped.
        phase = .recording
        record(.start, page: tracksSlides ? currentPage : nil, hostTime: start.hostTimeAtStart, sampleTime: 0)
        observe(statusUpdates, writer: writer)
        startMeter()
        startCaptions(clock: start.clock)
        if !notes.isEmpty { scheduleNotesSave(after: .zero) }
        do {
            try await writer.updateManifest { manifest in
                manifest.startedAt = start.startedAt
                manifest.hostTimeAtStart = start.hostTimeAtStart
                manifest.device = start.device
            }
        } catch {
            CaptureLog.capture.error("Manifest update failed: \(error.localizedDescription, privacy: .public)")
        }
        CaptureLog.capture.info("Recording \(id.uuidString, privacy: .public)")
    }

    /// Pauses (iPhone): the input stops, the audio so far is written and its segment closed, and
    /// the `pause` event and the manifest are on disk when this returns. The input stays claimed
    /// until `releaseInput()`, so the caller can finish its own updates before iOS may suspend
    /// the app. Throws when not recording, when the capture cannot pause, or when a failure
    /// stopped the recording meanwhile; then it is not paused.
    public func pause() async throws {
        guard phase == .recording else { throw CaptureError.notRecording }
        let hostTime = host.now()
        let wallClock = now()
        let mark = try await capture.pause()
        // A failure stopped the recording while the input went off.
        guard phase == .recording else { throw CaptureError.notRecording }
        phase = .paused
        level = 0
        let segments = mark.segments
        if !segments.isEmpty { self.segments = segments }
        record(.pause, page: tracksSlides ? currentPage : nil, hostTime: hostTime, sampleTime: mark.sampleTime, wallClock: wallClock)
        guard let writer else { return }
        eventsRevision += 1
        do {
            try await writer.writeEvents(events, revision: eventsRevision)
            if !segments.isEmpty {
                try await writer.updateManifest { $0.segments = segments }
            }
        } catch {
            CaptureLog.capture.error("Writing the pause failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Gives the input up while paused (iOS: the microphone indicator goes out).
    public func releaseInput() async {
        guard phase == .paused else { return }
        await capture.releaseInput()
    }

    /// Records again after `pause()`, into the same package: the next audio sits after the real
    /// time paused. Throws (and stays paused) when the input cannot start, e.g. during a call, and
    /// when a failure stopped the recording meanwhile.
    public func resume() async throws {
        guard phase == .paused else { throw CaptureError.notPaused }
        let resumed = try await capture.resume()
        guard phase == .paused else { throw CaptureError.notPaused }
        record(.resume, page: tracksSlides ? currentPage : nil, hostTime: resumed.hostTime, sampleTime: resumed.sampleTime)
        phase = .recording
    }

    /// Stamps the stop, closes the last segment and finalizes the package. Stopped while paused,
    /// the recording ends where its audio did.
    public func stop() async {
        guard phase == .recording || phase == .paused else { return }
        let hostTime = host.now()
        let pausedAt = phase == .paused ? pauses.open?.startSample : nil
        record(.stop, page: tracksSlides ? currentPage : nil, hostTime: hostTime, sampleTime: pausedAt)
        phase = .stopping
        endedAt = now()
        for task in liveTasks { task.cancel() }
        liveTasks = []
        notesSaveTask?.cancel()

        var stoppedSegments: [AudioSegmentInfo] = []
        do {
            stoppedSegments = try await capture.stop()
        } catch {
            CaptureLog.capture.error("Stopping capture failed: \(String(describing: error), privacy: .public)")
        }
        if !stoppedSegments.isEmpty { segments = stoppedSegments }
        if let writer {
            let endedAt = endedAt
            let segments = stoppedSegments
            do {
                eventsRevision += 1
                try await writer.writeEvents(events, revision: eventsRevision)
                notesRevision += 1
                try await writer.writeNotes(notesSnapshot(), revision: notesRevision)
                try await writer.updateManifest { manifest in
                    if !segments.isEmpty { manifest.segments = segments }
                    manifest.endedAt = endedAt
                }
            } catch {
                CaptureLog.capture.error("Finalizing package failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        level = 0
        captions = nil
        phase = .finished
        if let package { onFinalized?(package) }
    }

    /// Takes up a recording an earlier run of the app left paused (it was killed while paused):
    /// the package as it is on disk, its events and notes, paused on the slide it paused on.
    /// `resume()` then records on into it after the time paused, and `stop()` finishes it.
    /// Throws when the package did not end in a pause, or was recorded in another format.
    public func reopen(paused contents: LecturePackageContents) async throws {
        guard phase == .ready, writer == nil else { throw CaptureError.alreadyRecording }
        let manifest = contents.manifest
        guard manifest.endedAt == nil,
              contents.events.last?.kind == .pause,
              let pause = contents.pauses.open,
              let sampleTime = pause.startSample,
              let startedAt = manifest.startedAt,
              manifest.sampleRate == configuration.format.sampleRate
        else { throw CaptureError.notPaused }

        let writer = try LecturePackageWriter(package: contents.package, manifest: manifest)
        let statusUpdates = capture.statusUpdates()
        let clock = try await capture.reopen(PausedRecording(
            directory: contents.package.audioDirectory,
            format: configuration.format,
            segmentDuration: configuration.segmentDuration,
            segments: contents.segments,
            sampleTime: sampleTime,
            pausedAt: pause.startedAt
        ))
        package = contents.package
        self.writer = writer
        self.clock = clock
        self.startedAt = startedAt
        segments = contents.segments
        events = contents.events
        notes = Dictionary(contents.notes.map { ($0.page, $0) }, uniquingKeysWith: { _, last in last })
        if let page = contents.events.last?.page {
            currentPage = hasDeck ? min(max(1, page), pageCount) : max(1, page)
        }
        inputName = nil
        isInputAvailable = true
        level = 0
        phase = .paused
        observe(statusUpdates, writer: writer)
        startMeter()
        do {
            // The segments as found on disk (the manifest may lack a count after the kill).
            let segments = contents.segments
            try await writer.updateManifest { $0.segments = segments }
        } catch {
            CaptureLog.capture.error("Manifest update failed: \(error.localizedDescription, privacy: .public)")
        }
        CaptureLog.capture.info("Reopened \(manifest.id.uuidString, privacy: .public), paused")
    }

    // MARK: - Slides

    /// Next slide (→, Space). Stamps while recording. Returns whether the slide moved.
    @discardableResult
    public func next() -> Bool {
        navigate(to: currentPage + 1, kind: .slide, hostTime: host.now())
    }

    /// Previous slide (←). Stamps while recording. Returns whether the slide moved.
    @discardableResult
    public func previous() -> Bool {
        navigate(to: currentPage - 1, kind: .back, hostTime: host.now())
    }

    /// Any slide (filmstrip). Stamps while recording. Returns whether the slide moved.
    @discardableResult
    public func jump(to page: Int) -> Bool {
        navigate(to: page, kind: .jump, hostTime: host.now())
    }

    /// Flags this moment (F). Returns the flag's id while recording, else nil.
    @discardableResult
    public func flag(_ text: String? = nil) -> LectureEvent.ID? {
        let hostTime = host.now()
        guard phase == .recording else { return nil }
        return record(.flag, page: tracksSlides ? currentPage : nil, text: Self.nonBlank(text), hostTime: hostTime).id
    }

    /// Sets or clears a flag's text (until recording stops).
    public func setFlagText(_ text: String, for id: LectureEvent.ID) {
        guard acceptsNotes, let index = events.firstIndex(where: { $0.id == id && $0.kind == .flag }) else { return }
        events[index].text = Self.nonBlank(text)
        persistEvents()
    }

    // MARK: - Assignment

    /// Files the recording under another course or class (the iPhone's course menu): from now on
    /// the manifest says so. Before recording it only changes what `start` writes.
    public func reassign(courseID: UUID?, lectureID: UUID?, assignment: Assignment) async {
        self.courseID = courseID
        self.lectureID = lectureID
        self.assignment = assignment
        guard let writer else { return }
        do {
            try await writer.updateManifest { manifest in
                manifest.courseID = courseID
                manifest.lectureID = lectureID
                manifest.apply(assignment)
            }
        } catch {
            CaptureLog.capture.error("Manifest update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Notes

    /// Sets the quick note of a page (until recording stops).
    public func setNote(_ text: String, forPage page: Int) {
        guard acceptsNotes else { return }
        let date = now()
        if var note = notes[page] {
            guard note.text != text else { return }
            note.text = text
            note.updatedAt = date
            notes[page] = note
        } else {
            guard Self.nonBlank(text) != nil else { return }
            notes[page] = QuickNote(
                page: page,
                text: text,
                sampleTime: isRecording ? clock?.currentSampleTime() : nil,
                createdAt: date
            )
        }
        scheduleNotesSave()
    }

    // MARK: - Private

    private func navigate(to page: Int, kind: LectureEventKind, hostTime: UInt64) -> Bool {
        // Paused, a slide change could not be stamped: it waits for Resume.
        guard phase != .paused else { return false }
        // With a deck: its pages. Counting without one (iPhone): from 1 up, no upper bound.
        let inRange = hasDeck ? (1...pageCount).contains(page) : configuration.countsSlidesWithoutDeck && page >= 1
        guard inRange, page != currentPage else { return false }
        let from = currentPage
        currentPage = page
        if phase == .recording {
            record(kind, page: page, fromPage: from, hostTime: hostTime)
        }
        prefetchAround(page)
        return true
    }

    @discardableResult
    private func record(
        _ kind: LectureEventKind,
        page: Int?,
        fromPage: Int? = nil,
        text: String? = nil,
        hostTime: UInt64,
        sampleTime: Int64? = nil,
        wallClock: Date? = nil
    ) -> LectureEvent {
        let event = LectureEvent(
            kind: kind,
            page: page,
            fromPage: fromPage,
            text: text,
            sampleTime: sampleTime ?? clock?.sampleTime(atHostTime: hostTime),
            hostTime: hostTime,
            wallClock: wallClock ?? now()
        )
        events.append(event)
        persistEvents()
        return event
    }

    private func persistEvents() {
        guard let writer else { return }
        eventsRevision += 1
        let revision = eventsRevision
        let snapshot = events
        Task {
            do {
                try await writer.writeEvents(snapshot, revision: revision)
            } catch {
                CaptureLog.capture.error("Writing events failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func notesSnapshot() -> [QuickNote] {
        notes.values.filter { !$0.isBlank }.sorted { $0.page < $1.page }
    }

    private func scheduleNotesSave(after delay: Duration = .milliseconds(500)) {
        guard let writer else { return }
        notesSaveTask?.cancel()
        notesSaveTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.notesRevision += 1
            let revision = self.notesRevision
            do {
                try await writer.writeNotes(self.notesSnapshot(), revision: revision)
            } catch {
                CaptureLog.capture.error("Writing notes failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func observe(_ updates: AsyncStream<CaptureStatus>, writer: LecturePackageWriter) {
        statusTask = Task { [weak self] in
            for await status in updates {
                guard let self else { return }
                switch status {
                case .segmentsChanged(let segments) where !segments.isEmpty:
                    self.segments = segments
                    do {
                        try await writer.updateManifest { $0.segments = segments }
                    } catch {
                        CaptureLog.capture.error("Manifest update failed: \(error.localizedDescription, privacy: .public)")
                    }
                case .segmentsChanged:
                    // A capture that lost its writer knows no segments; keep the ones written
                    // (their start samples place audio after a gap), the reader measures files.
                    break
                case .inputChanged(let name):
                    self.inputName = name
                    self.isInputAvailable = name != nil
                case .inputLost:
                    self.isInputAvailable = false
                case .failed(let message):
                    // Also while paused: a write that failed while the pause drained the input
                    // means the audio cannot go on after a resume.
                    guard self.phase == .recording || self.phase == .paused else { continue }
                    await self.stop()
                    self.phase = .failed(.storage(message))
                }
            }
        }
    }

    private func startMeter() {
        let chunks = capture.audio(bufferingNewest: 1)
        liveTasks.append(Task { [weak self] in
            for await chunk in chunks {
                guard let self else { return }
                let level = chunk.meterLevel
                if abs(level - self.level) > 0.01 { self.level = level }
            }
        })
    }

    private func startCaptions(clock: RecordingClock) {
        guard let locale = configuration.captionLocale else { return }
        let capture = self.capture
        let writer = self.writer
        liveTasks.append(Task { [weak self] in
            do {
                let stream = LiveCaptioner.captions(locale: locale, clock: clock) {
                    capture.audio(bufferingNewest: 256)
                }
                for try await transcript in stream {
                    guard let self, self.phase == .recording else { return }
                    if self.captions == nil {
                        let identifier = transcript.localeIdentifier
                        _ = try? await writer?.updateManifest { $0.captionLocale = identifier }
                    }
                    self.captions = transcript
                }
            } catch {
                CaptureLog.captions.notice("Live captions off: \(String(describing: error), privacy: .public)")
                self?.captions = nil
            }
        })
    }

    private func prefetchAround(_ page: Int) {
        guard let deck else { return }
        prefetchTask?.cancel()
        let pages = [page, page + 1, page - 1, page + 2].filter { (1...pageCount).contains($0) }
        prefetchTask = Task(priority: .userInitiated) {
            await deck.prefetch(pages: pages, width: SlideWidth.display)
        }
    }

    private func makeManifest(id: UUID) -> LectureManifest {
        var manifest = LectureManifest(
            id: id,
            courseID: courseID,
            lectureID: lectureID,
            deck: deck.map {
                DeckReference(sha256: $0.sha256, pageCount: $0.pageCount, deckID: configuration.deckID)
            },
            format: configuration.format
        )
        manifest.apply(assignment)
        if deck == nil, configuration.countsSlidesWithoutDeck { manifest.slidesCounted = true }
        return manifest
    }

    private static func failure(from error: any Error) -> Failure {
        switch error as? CaptureError {
        case .microphoneDenied: .microphoneDenied
        case .noInputDevice: .noInputDevice
        case .inputBusy: .inputBusy
        case .engineFailed(let message): .engine(message)
        default: .storage(error.localizedDescription)
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return nil }
        return text
    }
}

#if DEBUG
// MARK: - Preview (debug builds)

extension LiveLectureSession {
    /// A slide stamp for `showPreview`: `page` came on screen `time` seconds into the recording.
    public struct PreviewStamp: Sendable, Hashable {
        public var page: Int
        public var time: TimeInterval

        public init(page: Int, time: TimeInterval) {
            self.page = page
            self.time = time
        }
    }

    /// Debug builds only: a session for `deckURL` that never records (its audio source refuses to
    /// start). Pair with `showPreview` for screenshots of the live screen.
    public static func openPreview(
        deckURL: URL?,
        deckSHA256: String? = nil,
        cacheDirectory: URL,
        pageTexts: [String]? = nil,
        captionLocale: Locale? = nil,
        countsSlidesWithoutDeck: Bool = false
    ) async throws -> LiveLectureSession {
        try await open(
            configuration: Configuration(
                directory: URL.temporaryDirectory.appending(path: "Socrates-preview", directoryHint: .isDirectory),
                captionLocale: captionLocale,
                countsSlidesWithoutDeck: countsSlidesWithoutDeck
            ),
            deckURL: deckURL,
            deckSHA256: deckSHA256,
            cacheDirectory: cacheDirectory,
            pageTexts: pageTexts,
            capture: PreviewAudioSource()
        )
    }

    /// Debug builds only: shows the session as if it had been recording for `elapsed` seconds,
    /// on `page`, with these slide stamps, captions, input level and quick note. Nothing is
    /// recorded or written (there is no package); the timer keeps running from `now`, unless
    /// `pausedFor`: then it was paused that many seconds ago and the timer stands at `elapsed`.
    public func showPreview(
        page: Int,
        elapsed: TimeInterval,
        stamps: [PreviewStamp],
        captions: CaptionTranscript?,
        level: Float,
        inputName: String?,
        note: String? = nil,
        pausedFor: TimeInterval? = nil,
        now: Date = Date()
    ) {
        guard phase == .ready, writer == nil else { return }
        let started = now.addingTimeInterval(-max(0, elapsed) - max(0, pausedFor ?? 0))
        if hasDeck {
            currentPage = min(max(1, page), pageCount)
        } else if configuration.countsSlidesWithoutDeck {
            currentPage = max(1, page)
        }
        startedAt = started
        self.inputName = inputName
        isInputAvailable = true
        self.level = level
        self.captions = captions
        var previous: Int?
        events = stamps.sorted { $0.time < $1.time }.enumerated().map { index, stamp in
            defer { previous = stamp.page }
            return LectureEvent(
                kind: index == 0 ? .start : .slide,
                page: stamp.page,
                fromPage: index == 0 ? nil : previous,
                sampleTime: Int64(stamp.time * sampleRate),
                hostTime: 0,
                wallClock: started.addingTimeInterval(stamp.time)
            )
        }
        if let note, !note.allSatisfy(\.isWhitespace) {
            notes[currentPage] = QuickNote(page: currentPage, text: note, createdAt: now)
        }
        if let pausedFor {
            events.append(LectureEvent(
                kind: .pause,
                page: tracksSlides ? currentPage : nil,
                sampleTime: Int64(elapsed * sampleRate),
                hostTime: 0,
                wallClock: now.addingTimeInterval(-max(0, pausedFor))
            ))
            self.level = 0
            phase = .paused
        } else {
            phase = .recording
        }
    }
}

/// Audio that never arrives: preview sessions cannot record.
private final class PreviewAudioSource: AudioCaptureSource {
    func requestPermission() async -> Bool { false }

    func start(in directory: URL, format: RecordingFormat, segmentDuration: Duration) async throws -> CaptureStart {
        throw CaptureError.noInputDevice
    }

    func stop() async throws -> [AudioSegmentInfo] { [] }

    func statusUpdates() -> AsyncStream<CaptureStatus> { AsyncStream { $0.finish() } }

    func audio(bufferingNewest limit: Int?) -> AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
}
#endif
