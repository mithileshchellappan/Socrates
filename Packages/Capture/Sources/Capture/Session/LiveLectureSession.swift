import Foundation
import Observation

/// One live lecture: the deck on screen, the recording, slide stamps, flags and quick notes.
///
/// Navigation before recording starts moves the deck without stamping (e.g. to start at
/// slide 13). While recording, every slide change and flag is stamped the moment the action
/// arrives: host time first, then mapped onto the recording clock. Everything is written to a
/// lecture package on disk as it happens; nothing here touches the database.
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
        case stopping
        case finished
        case failed(Failure)
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Recording consent for the course was withdrawn after the lecture was opened.
        case notConsented
        case microphoneDenied
        case noInputDevice
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

        public init(
            directory: URL,
            courseID: UUID? = nil,
            lectureID: UUID? = nil,
            deckID: UUID? = nil,
            captionLocale: Locale? = nil,
            format: RecordingFormat = .standard,
            segmentDuration: Duration = .seconds(300),
            initialPage: Int = 1
        ) {
            self.directory = directory
            self.courseID = courseID
            self.lectureID = lectureID
            self.deckID = deckID
            self.captionLocale = captionLocale
            self.format = format
            self.segmentDuration = segmentDuration
            self.initialPage = initialPage
        }
    }

    public let configuration: Configuration
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
        self.currentPage = deck.map { min(max(1, configuration.initialPage), $0.pageCount) } ?? 1
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

    /// Starting, recording or stopping: the session must stay alive.
    public var isCapturing: Bool {
        phase == .starting || phase == .recording || phase == .stopping
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
        case .ready, .starting, .recording: true
        case .failed: package == nil
        case .stopping, .finished: false
        }
    }

    public var hasDeck: Bool { pageCount > 0 }
    public var canGoNext: Bool { hasDeck && currentPage < pageCount }
    public var canGoPrevious: Bool { hasDeck && currentPage > 1 }
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

    /// Seconds recorded at `date` (frozen once recording stopped).
    public func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (endedAt ?? date).timeIntervalSince(startedAt))
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
        self.clock = start.clock
        self.startedAt = start.startedAt
        self.inputName = start.device?.name
        self.isInputAvailable = true
        // Stamp from here on, before any suspension point, so no key press goes unstamped.
        phase = .recording
        record(.start, page: hasDeck ? currentPage : nil, hostTime: start.hostTimeAtStart, sampleTime: 0)
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

    /// Stamps the stop, closes the last segment and finalizes the package.
    public func stop() async {
        guard phase == .recording else { return }
        let hostTime = host.now()
        record(.stop, page: hasDeck ? currentPage : nil, hostTime: hostTime)
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

    // MARK: - Slides

    /// Next slide (→, Space). Stamps while recording.
    public func next() {
        navigate(to: currentPage + 1, kind: .slide, hostTime: host.now())
    }

    /// Previous slide (←). Stamps while recording.
    public func previous() {
        navigate(to: currentPage - 1, kind: .back, hostTime: host.now())
    }

    /// Any slide (filmstrip). Stamps while recording.
    public func jump(to page: Int) {
        navigate(to: page, kind: .jump, hostTime: host.now())
    }

    /// Flags this moment (F). Returns the flag's id while recording, else nil.
    @discardableResult
    public func flag(_ text: String? = nil) -> LectureEvent.ID? {
        let hostTime = host.now()
        guard phase == .recording else { return nil }
        return record(.flag, page: hasDeck ? currentPage : nil, text: Self.nonBlank(text), hostTime: hostTime).id
    }

    /// Sets or clears a flag's text (until recording stops).
    public func setFlagText(_ text: String, for id: LectureEvent.ID) {
        guard acceptsNotes, let index = events.firstIndex(where: { $0.id == id && $0.kind == .flag }) else { return }
        events[index].text = Self.nonBlank(text)
        persistEvents()
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

    private func navigate(to page: Int, kind: LectureEventKind, hostTime: UInt64) {
        guard hasDeck, (1...pageCount).contains(page), page != currentPage else { return }
        let from = currentPage
        currentPage = page
        if phase == .recording {
            record(kind, page: page, fromPage: from, hostTime: hostTime)
        }
        prefetchAround(page)
    }

    @discardableResult
    private func record(
        _ kind: LectureEventKind,
        page: Int?,
        fromPage: Int? = nil,
        text: String? = nil,
        hostTime: UInt64,
        sampleTime: Int64? = nil
    ) -> LectureEvent {
        let event = LectureEvent(
            kind: kind,
            page: page,
            fromPage: fromPage,
            text: text,
            sampleTime: sampleTime ?? clock?.sampleTime(atHostTime: hostTime),
            hostTime: hostTime,
            wallClock: now()
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
                    guard self.phase == .recording else { continue }
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
        LectureManifest(
            id: id,
            courseID: configuration.courseID,
            lectureID: configuration.lectureID,
            deck: deck.map {
                DeckReference(sha256: $0.sha256, pageCount: $0.pageCount, deckID: configuration.deckID)
            },
            format: configuration.format
        )
    }

    private static func failure(from error: any Error) -> Failure {
        switch error as? CaptureError {
        case .microphoneDenied: .microphoneDenied
        case .noInputDevice: .noInputDevice
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
        captionLocale: Locale? = nil
    ) async throws -> LiveLectureSession {
        try await open(
            configuration: Configuration(
                directory: URL.temporaryDirectory.appending(path: "StudyPortal-preview", directoryHint: .isDirectory),
                captionLocale: captionLocale
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
    /// recorded or written (there is no package); the timer keeps running from `now`.
    public func showPreview(
        page: Int,
        elapsed: TimeInterval,
        stamps: [PreviewStamp],
        captions: CaptionTranscript?,
        level: Float,
        inputName: String?,
        note: String? = nil,
        now: Date = Date()
    ) {
        guard phase == .ready, writer == nil else { return }
        let started = now.addingTimeInterval(-max(0, elapsed))
        if hasDeck { currentPage = min(max(1, page), pageCount) }
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
        phase = .recording
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
