import Foundation
import Observation
import StudyCore

/// What the review screen shows and how it moves: the slide on screen, whether it follows the
/// playhead, and the navigation rules between the slide, the rail, the transcript and the player.
///
/// Follow is on by default: the slide (and with it the rail and transcript) tracks the playhead.
/// Moving to a slide by hand (←/→, the toolbar, a thumbnail) or scrubbing turns Follow off and
/// pauses; a thumbnail also seeks to that slide's first visit. Clicking a transcript line plays
/// from it with Follow back on. Turning Follow on re-syncs the slide to the playhead.
@MainActor
@Observable
public final class ReviewSession {
    /// Nil when the lecture has no recording.
    public let player: LecturePlayer?
    public private(set) var timeline: SlideTimeline
    /// Deck pages; 0 without a deck.
    public private(set) var pageCount: Int
    public private(set) var isFollowing = true
    /// The slide picked by hand (or the last one shown before Follow went off).
    private var manualPage: Int?

    public init(player: LecturePlayer?, pageCount: Int, timeline: SlideTimeline = .empty) {
        self.player = player
        self.pageCount = max(0, pageCount)
        self.timeline = timeline
        player?.setTimeline(timeline)
    }

    /// The slide on screen; nil without a deck.
    public var shownPage: Int? {
        guard pageCount > 0 else { return nil }
        if isFollowing, let page = player?.currentPage {
            return clamped(page)
        }
        return clamped(manualPage ?? player?.currentPage ?? timeline.spans.first { $0.page != nil }?.page ?? 1)
    }

    public var canFollow: Bool { player != nil && pageCount > 0 }

    // MARK: - Data

    public func update(timeline: SlideTimeline) {
        guard timeline != self.timeline else { return }
        self.timeline = timeline
        player?.setTimeline(timeline)
    }

    public func update(pageCount: Int) {
        self.pageCount = max(0, pageCount)
    }

    // MARK: - Navigation

    public var canGoPrevious: Bool { (shownPage ?? 1) > 1 }
    public var canGoNext: Bool { (shownPage ?? pageCount) < pageCount }

    /// Shows `page` by hand: Follow off, playback paused.
    public func show(page: Int) {
        guard pageCount > 0 else { return }
        manualPage = clamped(page)
        isFollowing = false
        player?.pause()
    }

    public func previousSlide() {
        guard let page = shownPage, page > 1 else { return }
        show(page: page - 1)
    }

    public func nextSlide() {
        guard let page = shownPage, page < pageCount else { return }
        show(page: page + 1)
    }

    /// A thumbnail click: that slide, paused at its first visit (if it was discussed).
    public func selectThumbnail(page: Int) async {
        show(page: page)
        if let visit = timeline.firstVisit(of: page) {
            await player?.seek(to: visit.start)
        }
    }

    /// Scrubbing: Follow off (the slide stays), paused, playhead moved.
    public func scrub(to seconds: Double) async {
        freezeShownPage()
        player?.pause()
        await player?.seek(to: seconds)
    }

    /// A transcript line or time chip: play from there with Follow on.
    public func play(from seconds: Double) async {
        isFollowing = true
        await player?.seek(to: seconds)
        player?.play()
    }

    /// Follow on re-syncs the slide to the playhead; off keeps the slide on screen.
    public func setFollowing(_ following: Bool) {
        guard following != isFollowing else { return }
        if following {
            isFollowing = true
        } else {
            freezeShownPage()
        }
    }

    public func toggleFollowing() {
        setFollowing(!isFollowing)
    }

    // MARK: - Transport

    public func togglePlayPause() {
        player?.togglePlayPause()
    }

    public func skip(by delta: Double) {
        player?.skip(by: delta)
    }

    // MARK: - Opening

    /// Opens at a slide and/or a time (the time wins for the player, the page for the slide when
    /// they disagree), else at `resume` (where review left off), else at the start. A time just
    /// before the page's first visit (under a second: a line that starts a beat early) opens that
    /// visit, following.
    public func open(page: Int?, time: Double?, plays: Bool, resume: Double?) async {
        if var time = time ?? (page == nil ? resume : nil) {
            if let page, let visit = timeline.firstVisit(of: page), visit.start > time, visit.start - time < 1 {
                time = visit.start
            }
            await player?.seek(to: time)
            if let page, page != player?.currentPage {
                show(page: page)
            } else {
                isFollowing = true
            }
        } else if let page {
            if let visit = timeline.firstVisit(of: page), let player {
                await player.seek(to: visit.start)
                isFollowing = true
            } else {
                show(page: page)
            }
        }
        if plays {
            player?.play()
        }
    }

    // MARK: - Private

    private func freezeShownPage() {
        manualPage = shownPage
        isFollowing = false
    }

    private func clamped(_ page: Int) -> Int {
        min(max(1, page), max(1, pageCount))
    }
}
