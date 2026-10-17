import Foundation
import StudyCore

/// When to remember where review left off and when a lecture counts as reviewed:
/// - the position is saved every `saveInterval` while playing (and once more on close);
/// - the lecture is marked reviewed once playback passes `reviewedFraction` of the recording or
///   reaches the last discussed slide; once per opening, and never after the user toggled it.
public struct ReviewProgressTracker: Sendable {
    public enum Action: Hashable, Sendable {
        case savePosition(Double)
        case markReviewed
    }

    public var saveInterval: Duration = .seconds(10)
    public var reviewedFraction = 0.9

    private var lastSave: ContinuousClock.Instant
    private var lastSavedTime: Double?
    /// Auto-marking is done (already reviewed, marked now, or toggled by hand).
    public private(set) var isSettled: Bool

    public init(isReviewed: Bool, savedPosition: Double?, openedAt: ContinuousClock.Instant) {
        isSettled = isReviewed
        lastSavedTime = savedPosition
        lastSave = openedAt
    }

    /// Feed every playhead update.
    public mutating func update(
        time: Double,
        isPlaying: Bool,
        duration: Double,
        lastDiscussedStart: Double?,
        now: ContinuousClock.Instant
    ) -> [Action] {
        guard isPlaying else { return [] }
        var actions: [Action] = []
        if now - lastSave >= saveInterval {
            lastSave = now
            if lastSavedTime.map({ abs($0 - time) >= 1 }) ?? true {
                lastSavedTime = time
                actions.append(.savePosition(time))
            }
        }
        if !isSettled {
            let pastFraction = duration > 0 && time >= duration * reviewedFraction
            let atLastSlide = lastDiscussedStart.map { time >= $0 } ?? false
            if pastFraction || atLastSlide {
                isSettled = true
                actions.append(.markReviewed)
            }
        }
        return actions
    }

    /// The position to save when the screen closes (nil when it is already saved).
    public mutating func close(time: Double) -> Double? {
        guard lastSavedTime.map({ abs($0 - time) >= 0.5 }) ?? true else { return nil }
        lastSavedTime = time
        return time
    }

    /// The user toggled Mark as Reviewed: no more automatic marking this time.
    public mutating func settle() {
        isSettled = true
    }
}

/// Writes review state for one lecture: `reviewPosition` and `reviewedAt`.
@MainActor
public final class ReviewStateKeeper {
    public let lectureID: Lecture.ID
    private let repository: LectureRepository
    private var tracker: ReviewProgressTracker
    private let clock = ContinuousClock()
    private let now: () -> Date
    private var lastWrite: Task<Void, Never>?

    public init(lecture: Lecture, store: RecordStore, now: @escaping () -> Date = { Date() }) {
        lectureID = lecture.id
        repository = LectureRepository(store: store)
        tracker = ReviewProgressTracker(
            isReviewed: lecture.reviewedAt != nil, savedPosition: lecture.reviewPosition, openedAt: ContinuousClock().now
        )
        self.now = now
    }

    /// Feed with the player's ticks.
    public func observe(time: Double, isPlaying: Bool, duration: Double, lastDiscussedStart: Double?) {
        let actions = tracker.update(
            time: time, isPlaying: isPlaying, duration: duration, lastDiscussedStart: lastDiscussedStart, now: clock.now
        )
        for action in actions {
            switch action {
            case .savePosition(let seconds): savePosition(seconds)
            case .markReviewed: setReviewed(now())
            }
        }
    }

    /// Saves where review stopped (screen closed).
    public func close(time: Double) {
        if let seconds = tracker.close(time: time) { savePosition(seconds) }
    }

    /// Mark as Reviewed (⇧⌘R): sets or clears `reviewedAt`.
    public func toggleReviewed(isReviewed: Bool) {
        tracker.settle()
        setReviewed(isReviewed ? nil : now())
    }

    /// Waits for queued writes (tests).
    public func flush() async {
        await lastWrite?.value
    }

    private func savePosition(_ seconds: Double) {
        let repository = repository
        let lectureID = lectureID
        enqueue { try await repository.setReviewPosition(lectureID, seconds: seconds) }
    }

    private func setReviewed(_ date: Date?) {
        let repository = repository
        let lectureID = lectureID
        enqueue { try await repository.setReviewed(lectureID, at: date) }
    }

    private func enqueue(_ write: @escaping @Sendable () async throws -> Lecture?) {
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            do {
                _ = try await write()
            } catch {
                ReviewLog.logger.error("Saving review state failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
