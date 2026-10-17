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
    enum InspectorTab: Hashable {
        case slide
        case lecture
    }

    let lecture: Lecture
    let course: Course?
    let recording: Recording?
    let deckID: Deck.ID?
    /// Nil without a deck (or when its PDF cannot be read): no rail, no slide.
    let deck: SlideDeck?
    let session: ReviewSession
    let services: StudyServices
    @ObservationIgnored let keeper: ReviewStateKeeper
    @ObservationIgnored let anchors: AnchorEditor

    /// A note editor (or another text field of the screen) has focus: slide and playback keys
    /// are off.
    var isEditingText = false
    var inspectorTab: InspectorTab = .slide
    var showsInspector = true
    /// A manual anchor is being written and re-aligned.
    private(set) var isRealigning = false

    var player: LecturePlayer? { session.player }

    init(
        lecture: Lecture, course: Course?, recording: Recording?, deckID: Deck.ID?, deck: SlideDeck?,
        session: ReviewSession, services: StudyServices, realign: @escaping AnchorEditor.Realign
    ) {
        self.lecture = lecture
        self.course = course
        self.recording = recording
        self.deckID = deckID
        self.deck = deck
        self.session = session
        self.services = services
        keeper = ReviewStateKeeper(lecture: lecture, store: services.records)
        anchors = AnchorEditor(store: services.records, realign: realign)
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

    /// Reads the lecture, its first recording and its deck, opens the deck and the audio, and
    /// moves to `target` (else where review left off). Nil when the lecture is gone.
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
            let recording = try await recordings.recordings(lectureID: lectureID).first
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
            let session = ReviewSession(player: player, pageCount: deck?.pageCount ?? 0, timeline: timeline)
            let model = ReviewModel(
                lecture: lecture, course: course, recording: recording, deckID: deckRow?.id, deck: deck,
                session: session, services: services, realign: realign
            )
            await session.open(page: target.page, time: target.time, plays: target.plays, resume: lecture.reviewPosition)
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
}

enum ReviewLog {
    static let logger = Log.logger(category: "review")
}
