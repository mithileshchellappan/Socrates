import Capture
import Foundation
import Observation
import Review
import StudyCore
import StudyUI

/// Everything one open lecture review needs that is not a database observation: the deck
/// renderer, the player and navigation state, review-state writes and the anchor editor.
@MainActor
@Observable
final class ReviewModel {
    typealias InspectorTab = ReviewInspectorTab

    let lecture: Lecture
    let course: Course?
    let recording: Recording?
    /// Every recording of the lecture, oldest first (a second recording of the same class, a
    /// backup recorder); the screen shows one at a time.
    let recordings: [Recording]
    let deckID: Deck.ID?
    /// Nil without a deck (or when its PDF cannot be read): no rail, no slide.
    let deck: SlideDeck?
    let session: ReviewSession
    let services: StudyServices
    @ObservationIgnored let keeper: ReviewStateKeeper
    @ObservationIgnored let anchors: AnchorEditor
    /// Hide, Revert Correction, the student's pins (M4).
    @ObservationIgnored let edits: StudyEdits
    /// Where the professor's anchor texts sit on the slides (nil without a deck).
    @ObservationIgnored let slideText: SlideTextLocator?

    /// A note editor (or another text field of the screen) has focus: slide and playback keys
    /// are off.
    var isEditingText = false
    /// M5: the Tutor tab's composer has focus (kept apart from `isEditingText`, which the note
    /// editors set and clear as focus moves between them).
    var isComposingChat = false
    var inspectorTab: InspectorTab = .slide
    var showsInspector = true
    /// M5: bumped by the Tutor tab's ⋯ ▸ New Chat.
    var newChatRequests = 0
    /// A manual anchor is being written and re-aligned.
    private(set) var isRealigning = false

    var player: LecturePlayer? { session.player }

    /// Another of the lecture's recordings was picked; the screen loads it.
    var requestedRecordingID: Recording.ID?

    /// A pin the student just added: its card opens for typing.
    var newPinID: Annotation.ID?

    /// M6: the tool drawing on the slide (Mac: the toolbar's pen / highlighter / eraser, P H E);
    /// nil: drawing is off and clicks on the slide pass through.
    private(set) var inkTool: InkTool?
    /// The pen or highlighter the eraser goes back to.
    @ObservationIgnored private var drawingTool: InkTool = .pen
    /// The deck's pages with ink (the rail's pencil, with the slides that have notes).
    var inkPages: Set<Int> = []
    /// What the flags' undo steps are registered with (dropped when the screen closes).
    @ObservationIgnored let flagUndo = FlagUndoTarget()
    /// Flag writes and their undo and redo, one after another.
    @ObservationIgnored private var flagWrite: Task<Void, Never>?

    init(
        lecture: Lecture, course: Course?, recording: Recording?, recordings: [Recording] = [], deckID: Deck.ID?, deck: SlideDeck?,
        session: ReviewSession, services: StudyServices, realign: @escaping AnchorEditor.Realign
    ) {
        self.lecture = lecture
        self.course = course
        self.recording = recording
        self.recordings = recordings.isEmpty ? recording.map { [$0] } ?? [] : recordings
        self.deckID = deckID
        self.deck = deck
        self.session = session
        self.services = services
        // `review_position` is on the first recording's clock; another one never moves it.
        let isFirst = recording == nil || recording?.id == self.recordings.first?.id
        keeper = ReviewStateKeeper(lecture: lecture, store: services.records, savesPosition: isFirst)
        anchors = AnchorEditor(store: services.records, realign: realign)
        edits = StudyEdits(store: services.records)
        slideText = deck.map { SlideTextLocator(url: $0.url) }
        let keeper = keeper
        session.player?.onTick = { [weak session] time in
            guard let session, let player = session.player else { return }
            keeper.observe(
                time: time, isPlaying: player.isPlaying, duration: player.duration,
                lastDiscussedStart: session.timeline.lastDiscussed?.start
            )
        }
    }

    // MARK: - Loading

    /// Reads the lecture, the recording `target` names (else its first) and its deck, opens the
    /// deck and the audio, and moves to `target` (else where review left off). Nil when the
    /// lecture is gone or the task was cancelled (a newer load replaced it): then nothing plays.
    static func load(
        lectureID: Lecture.ID,
        services: StudyServices,
        target: ReviewTarget,
        realign: @escaping AnchorEditor.Realign
    ) async -> ReviewModel? {
        let store = services.records
        do {
            guard let lecture = try await store.fetch(Lecture.self, id: lectureID) else { return nil }
            let course = try await store.fetch(Course.self, id: lecture.courseID)
            let recordings = RecordingRepository(store: store)
            let all = try await recordings.recordings(lectureID: lectureID)
            let recording = target.recordingID.flatMap { id in all.first { $0.id == id } } ?? all.first
            let deckID = try await deckID(lectureID: lectureID, database: services.database)
            var deckRow: Deck?
            if let deckID { deckRow = try await store.fetch(Deck.self, id: deckID) }
            let deck = await openDeck(deckRow, services: services)

            var player: LecturePlayer?
            var timeline = SlideTimeline.empty
            if let recording {
                let newPlayer = LecturePlayer(duration: recording.duration)
                let segments = try await recordings.segments(recordingID: recording.id)
                do {
                    try await newPlayer.load(PlaybackSource.sources(
                        segments: segments, sampleRate: recording.sampleRate, blobs: services.blobs
                    ))
                } catch {
                    ReviewLog.logger.error("Loading audio failed: \(String(describing: error), privacy: .public)")
                }
                let transcript = try await TranscriptRepository(store: store).segments(recordingID: recording.id)
                newPlayer.setCues(transcript.map(LecturePlayer.Cue.init))
                timeline = SlideTimeline(try await LectureRepository(store: store).timedSpans(lectureID: lectureID, recordingID: recording.id))
                player = newPlayer
            }
            var inkPages: Set<Int> = []
            if let deckRow, deck != nil {
                inkPages = try await SlideInkRepository(store: store).pages(deckID: deckRow.id)
            }
            guard !Task.isCancelled else { return nil }
            let session = ReviewSession(player: player, pageCount: deck?.pageCount ?? 0, timeline: timeline)
            let model = ReviewModel(
                lecture: lecture, course: course, recording: recording, recordings: all, deckID: deckRow?.id, deck: deck,
                session: session, services: services, realign: realign
            )
            model.inkPages = inkPages
            let resume = recording?.id == all.first?.id ? lecture.reviewPosition : nil
            await session.open(page: target.page, time: target.time, plays: target.plays && !Task.isCancelled, resume: resume)
            return model
        } catch {
            ReviewLog.logger.error("Opening lecture review failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The lecture's deck: the newest coarse span's (the lecture ↔ deck link alignment reads), else
    /// any span's.
    static func deckID(lectureID: Lecture.ID, database: any DatabaseReader) async throws -> Deck.ID? {
        try await database.read { db in
            let spans = try LectureDeckSpan
                .where { $0.lectureID.eq(lectureID) }
                .order(by: \.updatedAt)
                .fetchAll(db)
            return spans.last(where: { !$0.isTimed })?.deckID ?? spans.last?.deckID
        }
    }

    /// Opens the deck's PDF off the main actor; nil when there is none or it cannot be read.
    nonisolated static func openDeck(_ deck: Deck?, services: StudyServices) async -> SlideDeck? {
        guard let deck, let blob = deck.blob else { return nil }
        do {
            return try SlideDeck(
                url: services.blobs.url(for: blob),
                sha256: blob.sha256,
                cacheDirectory: services.paths.caches.appending(path: "Slides", directoryHint: .isDirectory),
                memoryBudgetBytes: ReviewModel.slideMemoryBudget
            )
        } catch {
            ReviewLog.logger.error("Opening slides failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// In-memory slide bitmaps: the slide on screen and the four prefetched around it at 2048 px
    /// (≈ 9 MB each) plus the visible thumbnails; everything else comes back from the disk cache.
    nonisolated static let slideMemoryBudget = 56 << 20

    // MARK: - Actions

    var canSetAnchor: Bool {
        recording != nil && deck != nil && !isRealigning
    }

    /// "Slide N starts here" (`page` nil: not on the slides from here) at `time`, then re-align.
    func setSlideStart(page: Int?, at time: Double) {
        guard let recording, !isRealigning else { return }
        isRealigning = true
        let anchors = anchors
        let lectureID = lecture.id
        let deckID = deckID
        Task {
            defer { isRealigning = false }
            do {
                try await anchors.setStart(page: page, at: time, lectureID: lectureID, recordingID: recording.id, deckID: deckID)
                // The slide on screen now starts at the playhead: follow it again.
                if page != nil { session.setFollowing(true) }
            } catch {
                ReviewLog.logger.error("Setting a slide marker failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Slide Starts Here (⌘\): the slide on screen starts at the playhead.
    func slideStartsHere() {
        guard let page = session.shownPage, let player else { return }
        setSlideStart(page: page, at: player.time)
    }

    func removeMarkers(_ ids: [SlideEvent.ID]) {
        guard let recording, !ids.isEmpty, !isRealigning else { return }
        isRealigning = true
        let anchors = anchors
        let lectureID = lecture.id
        Task {
            defer { isRealigning = false }
            do {
                try await anchors.remove(ids, lectureID: lectureID, recordingID: recording.id)
            } catch {
                ReviewLog.logger.error("Removing a slide marker failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Study pass items (M4)

    /// The professor's surname for pin cards ("Example").
    var professorSurname: String {
        course?.professors.first.map(SourceTrailText.surname) ?? ""
    }

    /// Hide: the AI or professor item is gone from every surface.
    func hide(_ id: Annotation.ID) {
        let edits = edits
        Task {
            do {
                try await edits.hide(id)
            } catch {
                ReviewLog.logger.error("Hiding an item failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Revert Correction on a transcript line: its segments read as transcribed again.
    func revertCorrections(_ line: TranscriptLine) {
        let edits = edits
        let ids = line.segmentIDs
        Task {
            do {
                try await edits.revertCorrections(segmentIDs: ids)
            } catch {
                ReviewLog.logger.error("Reverting a correction failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Add Pin on the slide on screen at `x`, `y` (0…1 from its top left); its card opens.
    func addPin(page: Int, x: Double, y: Double) {
        let edits = edits
        let lectureID = lecture.id
        let deckID = deckID
        Task {
            do {
                let pin = try await edits.addPin(lectureID: lectureID, deckID: deckID, page: page, x: x, y: y)
                newPinID = pin.id
            } catch {
                ReviewLog.logger.error("Adding a pin failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The student's pin text; a pin left empty is deleted when its card closes.
    func savePin(_ id: Annotation.ID, body: String) {
        let edits = edits
        let isEmpty = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Task {
            do {
                if isEmpty {
                    try await edits.deletePin(id)
                } else {
                    try await edits.setPinBody(id, body: body)
                }
            } catch {
                ReviewLog.logger.error("Saving a pin failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func deletePin(_ id: Annotation.ID) {
        let edits = edits
        Task {
            do {
                try await edits.deletePin(id)
            } catch {
                ReviewLog.logger.error("Deleting a pin failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Ink and flags (M6)

    /// Drawing needs a slide: a deck on screen.
    var canDraw: Bool { deck != nil && deckID != nil }

    /// A flag needs the recording on screen.
    var canFlag: Bool { recording != nil && player != nil }

    /// Pen or highlighter: on, or off when it is the tool on (one at a time). Eraser (only while
    /// drawing): on, or back to the pen or highlighter. Drawing turns Follow off, so the slide
    /// stays put while the student draws.
    func toggleInkTool(_ tool: InkTool) {
        guard canDraw else { return }
        switch tool {
        case .eraser:
            guard let current = inkTool else { return }
            inkTool = current == .eraser ? drawingTool : .eraser
        case .pen, .highlighter:
            inkTool = inkTool == tool ? nil : tool
            if inkTool != nil { drawingTool = tool }
        }
        if inkTool != nil { session.setFollowing(false) }
    }

    /// Esc, or Follow turned back on.
    func stopDrawing() {
        inkTool = nil
    }

    /// The rail's pencil follows a page's ink as it is drawn and erased.
    func setPage(_ page: Int, hasInk: Bool) {
        guard inkPages.contains(page) != hasInk else { return }
        if hasInk { inkPages.insert(page) } else { inkPages.remove(page) }
    }

    /// Flag (F): the student's flag at the playhead on the recording on screen, with the slide on
    /// screen. The red scrubber mark comes back through observation; Edit ▸ Undo removes it.
    func flag(undoManager: UndoManager?) {
        guard let recording, let player else { return }
        let rate = recording.sampleRate > 0 ? recording.sampleRate : 48_000
        let event = SlideEvent(
            recordingID: recording.id,
            lectureID: lecture.id,
            kind: .flag,
            deckID: deck == nil ? nil : deckID,
            pageNumber: session.shownPage,
            sampleTime: Int64((max(0, player.time) * rate).rounded()),
            wallClock: services.records.currentDate
        )
        writeFlag(event, adds: true, undoManager: undoManager)
    }

    /// Adds or removes the flag and registers the opposite step.
    private func writeFlag(_ event: SlideEvent, adds: Bool, undoManager: UndoManager?) {
        let edits = edits
        let previous = flagWrite
        flagWrite = Task {
            await previous?.value
            do {
                if adds {
                    try await edits.addFlag(event)
                } else {
                    try await edits.deleteFlag(event.id)
                }
            } catch {
                ReviewLog.logger.error("Saving a flag failed: \(String(describing: error), privacy: .public)")
            }
        }
        undoManager?.registerUndo(withTarget: flagUndo) { [weak self] _ in
            self?.writeFlag(event, adds: !adds, undoManager: undoManager)
        }
    }

    func toggleReviewed(isReviewed: Bool) {
        keeper.toggleReviewed(isReviewed: isReviewed)
    }

    /// The screen goes away: stop playback and remember where review stopped.
    func close() {
        if let player {
            player.pause()
            keeper.close(time: player.time)
        }
    }

    /// A load that was replaced before it was shown: stop it without writing anything.
    func discard() {
        player?.pause()
    }
}

/// The identity a review's flag undo steps are registered with.
@MainActor
final class FlagUndoTarget {}

enum ReviewLog {
    static let logger = Log.logger(category: "review")
}
