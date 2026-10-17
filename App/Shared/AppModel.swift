import Capture
import Foundation
import Observation
import Processing
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

    /// The lecture being captured, owned here so recording outlives its window.
    private(set) var live: LiveCapture?
    /// The sheet the main window shows.
    var sheet: AppSheet?
    /// iOS/iPadOS: the live lecture covers the screen while true (macOS uses its own window).
    var isLivePresented = false
    /// A failure to show once (import, opening a deck).
    var failure: String?
    /// Set when an import finishes, so the main window can show where it went.
    var lastImported: ImportedLecture?

    @ObservationIgnored private var didStartBackgroundWork = false

    init(services: StudyServices?, launchError: String? = nil) {
        self.services = services
        self.launchError = launchError
        if let services, let store = try? WhisperModelStore.shared() {
            let engine = WhisperKitEngine(store: store)
            processor = LectureProcessor(services: services, engine: engine, onIdle: {
                // The model holds about 1.5 GB; load it again only for the next job.
                await engine.decoder.unload()
            })
        } else {
            processor = nil
        }
    }

    static func launch() -> AppModel {
        do {
            return AppModel(services: try StudyServices.live())
        } catch {
            Log.app.fault("Could not open the library: \(error.localizedDescription, privacy: .public)")
            return AppModel(services: nil, launchError: error.localizedDescription)
        }
    }

    // MARK: - Background work

    /// Imports captures a crash left behind, re-queues interrupted jobs and starts processing.
    /// Runs once per launch.
    func startBackgroundWork() async {
        guard !didStartBackgroundWork, let services, let processor else { return }
        didStartBackgroundWork = true
        let recording = live?.session.package.map { Set([$0.url]) } ?? []
        let recovered = await LectureImporter(services: services)
            .importPendingCaptures(in: services.paths.recordings, excluding: recording)
        if !recovered.isEmpty {
            Log.app.notice("Recovered \(recovered.count) captured lecture(s)")
        }
        do {
            try await processor.recover()
        } catch {
            Log.jobs.error("Job recovery failed: \(error.localizedDescription, privacy: .public)")
        }
        await processor.wake()
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
        let courseID = course.id
        session.onFinalized = { [weak self] package in
            self?.fileCapture(package, courseID: courseID)
        }
        live = LiveCapture(session: session, course: course, deck: deck, lectureID: lectureID, openedAt: Date())
    }

    /// Files a finished capture into the library and queues its processing.
    private func fileCapture(_ package: LecturePackage, courseID: Course.ID) {
        guard let services else { return }
        let processor = processor
        Task {
            do {
                let imported = try await LectureImporter(services: services).importCapture(at: package.url, courseID: courseID)
                lastImported = imported
                await processor?.wake()
            } catch {
                Log.importer.error("Capture import failed: \(String(describing: error), privacy: .public)")
                failure = error.localizedDescription
            }
        }
    }

    /// Lets go of the live session once its screen is closed, unless it is starting, recording or
    /// stopping (it must stay owned until the package is final).
    func closeLiveLecture() {
        guard let live, !live.session.isCapturing else { return }
        self.live = nil
    }

    // MARK: - Import

    enum ImportSource: Hashable {
        /// A `.lecture` package from live capture.
        case capture(URL)
        /// An audio file, with an optional slide PDF.
        case recording(audio: URL, deck: URL?)
    }

    /// Imports a lecture and queues its processing. Returns nil on failure (shown via `failure`).
    @discardableResult
    func importLecture(_ source: ImportSource, courseID: Course.ID) async -> ImportedLecture? {
        guard let services else { return nil }
        let urls: [URL] = switch source {
        case .capture(let url): [url]
        case .recording(let audio, let deck): [audio] + (deck.map { [$0] } ?? [])
        }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        do {
            let importer = LectureImporter(services: services)
            let imported: ImportedLecture
            switch source {
            case .capture(let url):
                imported = try await importer.importCapture(at: url, courseID: courseID)
            case .recording(let audio, let deck):
                imported = try await importer.importRecording(audio: audio, deck: deck, courseID: courseID)
            }
            lastImported = imported
            await processor?.wake()
            return imported
        } catch {
            Log.importer.error("Import failed: \(String(describing: error), privacy: .public)")
            failure = error.localizedDescription
            return nil
        }
    }

    /// Puts a slide PDF into the library for `courseID`.
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

    /// Creates a course from the minimal fields the capture and import sheets offer.
    func createCourse(_ draft: CourseDraft) async -> Course? {
        guard let services else { return nil }
        do {
            let count = try await services.records.count(Course.self)
            return try await services.records.save(Course(
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                language: draft.language,
                adminLanguage: "de",
                colorHex: CourseDraft.palette[count % CourseDraft.palette.count],
                recordingConsentAt: draft.records ? Date() : nil,
                sortOrder: count
            ))
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    /// Records (or withdraws) recording consent for a course.
    func setRecordingConsent(_ granted: Bool, for course: Course) async -> Course? {
        guard let services else { return nil }
        var course = course
        course.recordingConsentAt = granted ? (course.recordingConsentAt ?? Date()) : nil
        return try? await services.records.save(course)
    }

    func retryProcessing(lectureID: Lecture.ID) {
        let processor = processor
        Task { _ = try? await processor?.retry(lectureID: lectureID) }
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
    case importLecture(courseID: Course.ID?)

    var id: Self { self }
}

/// The few course fields needed to file a lecture before course setup (M1) exists.
struct CourseDraft: Hashable {
    var name = ""
    var language = "en"
    var records = false

    var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static let languages: [(code: String, name: String)] = [("en", "English"), ("de", "Deutsch")]
    static let palette = ["#0a84ff", "#30b0c7", "#ff9f0a", "#bf5af2", "#34c759", "#ff375f"]
}
