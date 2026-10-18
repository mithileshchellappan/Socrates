import Foundation
import SQLiteData

// Record types added in schema v8 (M4: the AI study pass). docs/plan-m4.md §2–3.

// MARK: - Study pass

/// One unit of the study pass's work on a lecture: a read block, the synthesis, a research pick.
/// Written only by `StudyPassPipeline` (package `StudyPass`). The annotations a unit wrote point
/// at it (`annotation.study_unit_id`, CASCADE), so deleting a unit that no longer exists removes
/// its rows, and a re-run replaces them.
///
/// A unit is unique per (lecture, stage, key) by code (no UNIQUE index, CloudKit rules). A `done`
/// unit whose `inputHash` still matches is never called again.
@Table("study_unit")
public struct StudyUnit: StudyRecord {
    public let id: UUID
    @Column("lecture_id") public var lectureID: Lecture.ID
    public var stage: StudyStage
    /// Stable within (lecture, stage): "p13-24" (deck pages 13–24), "t0-15" (minutes, a lecture
    /// without a deck), "lecture" (synthesis), "research:<12 hex of SHA-256 of the pick's title,
    /// query and slide>".
    public var key: String
    /// SHA-256 (hex) of the unit's exact prompt inputs + `StudyPass.promptVersion`.
    @Column("input_hash") public var inputHash: String
    /// pending (waits, also through a usage pause), skipped (too little speech, no call), done,
    /// failed (attempts used up, or over the lecture's budget).
    public var state: ExtractionState
    /// Failed attempts so far (service trouble — usage limit, not installed, signed out — does
    /// not count).
    public var attempts: Int
    /// Why it failed (readable, no transcript text, no secrets).
    public var error: String?
    /// The call whose answer was written (the last one of a multi-call run).
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("finished_at") public var finishedAt: Date?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        lectureID: Lecture.ID,
        stage: StudyStage,
        key: String,
        inputHash: String = "",
        state: ExtractionState = .pending,
        attempts: Int = 0,
        error: String? = nil,
        apiCallID: APICall.ID? = nil,
        finishedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.lectureID = lectureID
        self.stage = stage
        self.key = key
        self.inputHash = inputHash
        self.state = state
        self.attempts = attempts
        self.error = error
        self.apiCallID = apiCallID
        self.finishedAt = finishedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// After this many failed attempts a unit is `failed` until its inputs change.
    public static let maximumAttempts = 3
}
