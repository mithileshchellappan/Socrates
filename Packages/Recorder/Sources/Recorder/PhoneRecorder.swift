import Capture
import Courses
import Foundation
import Observation
import RecorderActivity
import StudyCore

/// The iPhone's recorder (M7, docs/plan-m7.md §4, §5.1): one recording at a time over Capture's
/// `LiveLectureSession`, with slide stamps, the Live Activity and the outbox of phone captures
/// (`AppPaths.phoneCaptures`), which the student shares to the Mac as capture bundles. Nothing
/// it records enters the phone's library; the Mac files and processes it.
///
/// The app owns one for its lifetime (recording outlives the screen) and calls `activate()` at
/// launch; the screen calls `prepare()` when it opens.
@MainActor
@Observable
public final class PhoneRecorder {
    public let services: StudyServices

    /// A recording is running (starting, recording or stopping): the shell's Record button shows
    /// it, and Record opens this recording instead of a new one.
    public private(set) var isRecording = false

    /// The courses that may record (recording consent), in the sidebar's order.
    public private(set) var courses: [Course] = []
    /// The course the recording is (or will be) for.
    public private(set) var course: Course?
    /// The course's class on now (`CourseSchedule.session(forRecordingAt:)`), if it has one.
    public private(set) var classSession: LectureSession?
    /// The lecture filed to that class; its deck shows when the phone has the file.
    public private(set) var lecture: Lecture?
    /// The recording: ready, recording, finished (or failed to start).
    public private(set) var session: LiveLectureSession?
    /// The outbox, newest first (the recording in progress is left out).
    public private(set) var captures: [PhoneCapture] = []
    /// The capture Stop just finished: the screen shows it with Share until it opens again.
    public private(set) var finished: PhoneCapture?
    /// Debug renders: never records, never touches the outbox.
    public private(set) var isPreview = false

    @ObservationIgnored private var colors: [Course.ID: String] = [:]
    /// The recording the Live Activity was started for (nil: none is showing).
    @ObservationIgnored private var activityID: UUID?
    @ObservationIgnored private var lastActivityState: RecordingActivityState?
    /// Activity updates run one after another, so a quick run of taps never shows an old slide.
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private static let lastCourseKey = "StudyPortal.PhoneRecorder.lastCourseID"

    public init(services: StudyServices, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
    }

    // MARK: - Launch

    /// Registers the Live Activity buttons' handler (`RecorderControl.handler`). Call once at
    /// launch, before the first scene. Also removes what an earlier run left: shared bundles in
    /// the temporary folder, and Live Activities of a recording the app no longer has.
    public func activate() {
        RecorderControl.handler = { [weak self] command, recordingID in
            await self?.handle(command, recordingID: recordingID)
        }
        Task.detached(priority: .utility) {
            CaptureBundle.removeTemporaryBundles(olderThan: 0)
        }
        #if os(iOS)
        let keeping = activityID
        Task { await RecordingActivityController.endAll(keeping: keeping) }
        #endif
    }

    /// Readies the screen: the courses that may record, the default course (the class on now,
    /// else the last one used), a session for it and the outbox. While recording it only reloads
    /// the outbox.
    public func prepare(now: Date = Date()) async {
        guard !isPreview else { return }
        if session?.isCapturing == true {
            await reloadCaptures()
            return
        }
        finished = nil
        await loadCourses()
        let schedule = CourseSchedule(services: services)
        var chosen: Course?
        var classOn: LectureSession?
        if let on = try? await schedule.session(forRecordingAt: now), let match = courses.first(where: { $0.id == on.courseID }) {
            chosen = match
            classOn = on
        } else if let last = defaults.string(forKey: Self.lastCourseKey).flatMap(UUID.init(uuidString:)),
                  let match = courses.first(where: { $0.id == last }) {
            chosen = match
        } else {
            chosen = courses.first
        }
        course = chosen
        if classOn == nil, let chosen {
            classOn = try? await schedule.session(forRecordingAt: now, courseID: chosen.id)
        }
        classSession = classOn
        lecture = await lecture(of: classOn)
        await openSession()
        await reloadCaptures()
    }

    // MARK: - Course

    /// Records for `course` instead (the course menu). Before recording the deck follows the
    /// course's class; while recording the manifest and the Live Activity follow it.
    public func select(_ course: Course) async {
        guard course.id != self.course?.id, !isPreview else { return }
        defaults.set(course.id.uuidString, forKey: Self.lastCourseKey)
        let start = session?.startedAt ?? Date()
        self.course = course
        classSession = try? await CourseSchedule(services: services).session(forRecordingAt: start, courseID: course.id)
        lecture = await lecture(of: classSession)
        if let session, session.isCapturing {
            await session.reassign(courseID: course.id, lectureID: lecture?.id, assignment: assignment())
            updateActivity()
        } else {
            await openSession()
        }
    }

    // MARK: - Recording

    /// The course can record (it has consent and a session is ready).
    public var canRecord: Bool {
        course != nil && (session?.canStartRecording ?? false) && !isPreview
    }

    /// Starts recording into the outbox, then the Live Activity (when Live Activities are on).
    public func start() async {
        guard canRecord, let session else { return }
        do {
            try FileManager.default.createDirectory(at: services.paths.phoneCaptures, withIntermediateDirectories: true)
        } catch {
            RecorderLog.recorder.error("No outbox folder: \(error.localizedDescription, privacy: .public)")
        }
        finished = nil
        isRecording = true
        await session.start()
        guard session.isRecording else {
            isRecording = session.isCapturing
            return
        }
        if let course { defaults.set(course.id.uuidString, forKey: Self.lastCourseKey) }
        #if os(iOS)
        if let id = session.package?.id, let state = activityState(),
           RecordingActivityController.start(recordingID: id, state: state) {
            activityID = id
            lastActivityState = state
        }
        #endif
    }

    /// Next slide: stamps it on the recording clock (→ on the Mac).
    public func next() {
        session?.next()
        updateActivity()
    }

    /// Previous slide (never below 1).
    public func previous() {
        session?.previous()
        updateActivity()
    }

    /// Flags this moment.
    public func flag() {
        session?.flag()
    }

    /// Stops recording; the package is final, the capture joins the outbox and the Live Activity
    /// ends. The screen asks first; the Lock Screen's Stop Recording does not.
    public func stop() async {
        guard let session, session.isRecording else { return }
        await session.stop()
        if isPreview { isRecording = false }
    }

    /// Seconds recorded at `date` (frozen once stopped).
    public func elapsed(at date: Date) -> TimeInterval {
        session?.elapsed(at: date) ?? 0
    }

    // MARK: - Names

    /// "DC Lecture 2"; the short name and the day without a known class.
    public var sessionName: String {
        guard let course else { return "" }
        return RecorderText.sessionName(course: course, session: classSession, day: recordingDay)
    }

    /// "Lecture 2 · Tue 13 Oct" (under the timer).
    public var sessionLine: String {
        RecorderText.sessionLine(session: classSession, day: recordingDay)
    }

    /// The class's day, else the recording's.
    private var recordingDay: Date {
        classSession?.startsAt ?? session?.startedAt ?? Date()
    }

    /// What the Live Activity shows now (nil before recording): the parity screen draws the Lock
    /// Screen view (`Widgets/Shared`) from it.
    public var liveActivityState: RecordingActivityState? {
        activityState(stoppedAt: session?.endedAt)
    }

    /// A course's colour, for outbox rows.
    public func colorHex(of courseID: Course.ID?) -> String? {
        courseID.flatMap { colors[$0] }
    }

    // MARK: - Outbox

    /// Deletes a capture from the phone (the screen asks first, naming it).
    public func delete(_ capture: PhoneCapture) async {
        guard !isPreview, capture.id != session?.package?.id || session?.isCapturing != true else { return }
        let url = capture.package.url
        await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                RecorderLog.recorder.error("Delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }.value
        if finished?.id == capture.id { finished = nil }
        await reloadCaptures()
    }

    public func reloadCaptures() async {
        guard !isPreview else { return }
        let recording = session?.isCapturing == true ? session?.package?.id : nil
        captures = await PhoneCapture.load(in: services.paths.phoneCaptures, excluding: recording)
    }

    // MARK: - Private

    private func handle(_ command: RecorderCommand, recordingID: UUID) async {
        // A button of an older activity never acts on this recording.
        guard let session, session.isRecording, session.package?.id == recordingID else { return }
        switch command {
        case .nextSlide: next()
        case .stop: await stop()
        }
    }

    private func loadCourses() async {
        let all = (try? await services.database.read { db in
            try Course.order(by: \.sortOrder).fetchAll(db)
        }) ?? []
        colors = Dictionary(all.map { ($0.id, $0.colorHex) }, uniquingKeysWith: { first, _ in first })
        courses = all.filter(\.recordsLectures)
    }

    /// The lecture filed to the class, else the course's lecture of its number.
    private func lecture(of classOn: LectureSession?) async -> Lecture? {
        guard let classOn else { return nil }
        let lectures = LectureRepository(store: services.records)
        if let filed = try? await lectures.lecture(sessionID: classOn.id) { return filed }
        guard classOn.kind == .lecture, let number = classOn.number else { return nil }
        return (try? await lectures.lectures(courseID: classOn.courseID))?.first { $0.number == number }
    }

    /// The lecture's deck when its file is on the phone (blobs do not sync).
    private func deckOnPhone(of lecture: Lecture?) async -> (Deck, [DeckPage])? {
        guard let lecture else { return nil }
        let spans = (try? await LectureRepository(store: services.records).spans(lectureID: lecture.id)) ?? []
        guard let deckID = spans.first(where: { $0.startTime == nil })?.deckID,
              let deck = try? await services.records.fetch(Deck.self, id: deckID),
              let blob = deck.blob, services.blobs.contains(blob)
        else { return nil }
        let pages = (try? await DeckRepository(store: services.records).pages(deckID: deck.id)) ?? []
        return (deck, pages)
    }

    /// A ready session for the chosen course, showing its class's deck when the phone has it.
    private func openSession() async {
        guard let course else {
            session = nil
            return
        }
        let deck = await deckOnPhone(of: lecture)
        let configuration = LiveLectureSession.Configuration(
            directory: services.paths.phoneCaptures,
            courseID: course.id,
            lectureID: lecture?.id,
            deckID: deck?.0.id,
            countsSlidesWithoutDeck: true,
            assignment: assignment()
        )
        let cache = services.paths.caches.appending(path: "Slides", directoryHint: .isDirectory)
        let opened: LiveLectureSession
        if let deck, let blob = deck.0.blob, let withDeck = try? await LiveLectureSession.open(
            configuration: configuration, deckURL: services.blobs.url(for: blob), deckSHA256: deck.0.blobSHA256,
            cacheDirectory: cache, pageTexts: deck.1.isEmpty ? nil : deck.1.map(\.text)
        ) {
            opened = withDeck
        } else {
            opened = LiveLectureSession(configuration: configuration, deck: nil)
        }
        opened.consentCheck = { [weak self] in
            guard let self, let id = self.course?.id else { return false }
            return (try? await self.services.records.fetch(Course.self, id: id))?.recordsLectures ?? false
        }
        opened.onFinalized = { [weak self] package in
            Task { await self?.didFinish(package) }
        }
        session = opened
    }

    /// The package is final (Stop, or a failure that stopped the recording).
    private func didFinish(_ package: LecturePackage) async {
        isRecording = false
        #if os(iOS)
        if let id = activityID {
            let final = activityState(stoppedAt: session?.endedAt ?? Date())
            activityID = nil
            lastActivityState = nil
            let previous = activityTask
            activityTask = Task {
                await previous?.value
                await RecordingActivityController.end(recordingID: id, state: final)
            }
        }
        #endif
        await reloadCaptures()
        finished = captures.first { $0.id == package.id }
    }

    private func assignment() -> LiveLectureSession.Assignment {
        LiveLectureSession.Assignment(
            courseName: course?.name,
            courseShortName: course?.shortName,
            sessionNumber: classSession?.kind == .lecture ? (lecture?.number ?? classSession?.number) : nil,
            sessionName: sessionName
        )
    }

    private func activityState(stoppedAt: Date? = nil) -> RecordingActivityState? {
        guard let session, let course, let startedAt = session.startedAt else { return nil }
        return RecordingActivityState(
            courseName: course.name,
            courseColorHex: course.colorHex,
            sessionName: sessionName,
            slide: session.currentPage,
            slideCount: session.hasDeck ? session.pageCount : nil,
            startedAt: startedAt,
            stoppedAt: stoppedAt
        )
    }

    /// Updates the Live Activity when what it shows changed (a stamp, the course).
    private func updateActivity() {
        #if os(iOS)
        guard let id = activityID, let state = activityState(), state != lastActivityState else { return }
        lastActivityState = state
        let previous = activityTask
        activityTask = Task {
            await previous?.value
            await RecordingActivityController.update(recordingID: id, state: state)
        }
        #endif
    }

    // MARK: - Preview (debug builds)

    #if DEBUG
    /// Debug builds only (parity renders): Data Centers's Lecture 2 at slide 17 of 88 (the
    /// deck when its file is in the library), 38:41 in, a few stamps and an input level. It never
    /// records. `stopped`: the screen after Stop, with the capture and an outbox. `startsActivity`
    /// also shows its Live Activity (iOS).
    public static func preview(services: StudyServices, stopped: Bool = false, startsActivity: Bool = false) async throws -> PhoneRecorder {
        let recorder = PhoneRecorder(services: services)
        recorder.isPreview = true
        await recorder.loadCourses()
        let course = recorder.courses.first { $0.shortName == "DC" || $0.name == "Data Centers" } ?? recorder.courses.first
        recorder.course = course
        var lecture: Lecture?
        if let course {
            lecture = try await LectureRepository(store: services.records).lectures(courseID: course.id).first { $0.number == 2 }
        }
        var classOn: LectureSession?
        if let sessionID = lecture?.lectureSessionID {
            classOn = try await services.records.fetch(LectureSession.self, id: sessionID)
        } else if let course {
            let courseID = course.id
            classOn = try await services.database.read { db in
                try LectureSession
                    .where { $0.courseID.eq(courseID) && $0.kind.eq(SessionKind.lecture) && $0.number.eq(2) && !$0.isCancelled }
                    .fetchOne(db)
            }
        }
        recorder.classSession = classOn
        recorder.lecture = lecture
        let deck = await recorder.deckOnPhone(of: lecture)
        let session = try await LiveLectureSession.openPreview(
            deckURL: deck?.0.blob.map(services.blobs.url(for:)),
            deckSHA256: deck?.0.blobSHA256,
            cacheDirectory: services.paths.caches.appending(path: "Slides", directoryHint: .isDirectory),
            pageTexts: deck.map { $0.1.map(\.text) },
            countsSlidesWithoutDeck: true
        )
        await session.reassign(courseID: course?.id, lectureID: lecture?.id, assignment: recorder.assignment())
        let elapsed: TimeInterval = 38 * 60 + 41
        let stamps: [(page: Int, time: TimeInterval)] = [(1, 0), (6, 431), (11, 1_142), (15, 1_806), (16, 2_217), (17, elapsed - 3.3)]
        session.showPreview(
            page: 17,
            elapsed: elapsed,
            stamps: stamps.map { LiveLectureSession.PreviewStamp(page: $0.page, time: $0.time) },
            captions: nil,
            level: 0.55,
            inputName: "iPhone Microphone"
        )
        recorder.session = session
        recorder.isRecording = true
        if stopped {
            await session.stop()
            recorder.isRecording = false
            recorder.captures = recorder.previewOutbox(day: classOn?.startsAt ?? Date())
            recorder.finished = recorder.captures.first
        }
        #if os(iOS)
        if startsActivity, !stopped, let state = recorder.activityState() {
            let id = UUID()
            if RecordingActivityController.start(recordingID: id, state: state) {
                recorder.activityID = id
                recorder.lastActivityState = state
            }
        }
        #endif
        return recorder
    }

    /// The outbox after Stop: this lecture first, then two earlier ones (packages that do not
    /// exist; Share and Delete do nothing in a preview).
    private func previewOutbox(day: Date) -> [PhoneCapture] {
        let folder = URL.temporaryDirectory.appending(path: "StudyPortal-preview", directoryHint: .isDirectory)
        func capture(_ title: String, _ course: Course?, _ start: Date, _ duration: TimeInterval, _ stamps: Int) -> PhoneCapture {
            let id = UUID()
            return PhoneCapture(
                id: id, package: LecturePackage(url: folder.appending(path: "\(id.uuidString).lecture", directoryHint: .isDirectory)),
                title: title, courseID: course?.id, startedAt: start, duration: duration, stampCount: stamps, isComplete: true
            )
        }
        var outbox = [capture(sessionName, course, day, 68 * 60 + 13, 37)]
        let others = courses.filter { $0.id != course?.id }
        if let first = others.first {
            outbox.append(capture(RecorderText.sessionName(course: first, session: nil, day: day), first, day.addingTimeInterval(-4 * 3600), 44 * 60 + 34, 18))
        }
        if others.count > 1 {
            let second = others[1]
            let earlier = day.addingTimeInterval(-86_400)
            outbox.append(capture(RecorderText.sessionName(course: second, session: nil, day: earlier), second, earlier, 71 * 60 + 43, 9))
        }
        return outbox
    }
    #endif
}
