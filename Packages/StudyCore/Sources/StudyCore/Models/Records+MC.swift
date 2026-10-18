import Foundation
import SQLiteData

// Record types added in schema v12 (milestone mc: the study coach). docs/plan-coach.md §3–4,
// docs/schema.md.

// MARK: - The plan

/// One block of a day's plan (research §6.2): what to open, for how long, and why. Written by the
/// coach's plan engine from today to two weeks ahead; today's blocks stay once the day began (done
/// and started ones never change), later days are rewritten on every replan. Today's hero and
/// Study's current block are the first open block of today by `sort_order`.
@Table("study_block")
public struct StudyBlock: StudyRecord {
    public let id: UUID
    /// The plan day (the university's time zone).
    public var day: CalendarDay
    /// Position in the day (0 first).
    @Column("sort_order") public var sortOrder: Int
    public var kind: StudyBlockKind
    /// The block's course (nil for a round across courses: `courseIDs`).
    @Column("course_id") public var courseID: Course.ID?
    /// The courses a round mixes (its eyebrow's dots and names), in course order.
    @Column("course_ids", as: [Course.ID].JSONRepresentation.self) public var courseIDs: [Course.ID]
    /// As the hero titles it: "Online quiz 1", "Lecture 2", "18 questions", "J&M §4.9".
    public var title: String
    /// The scope after the title: "slides 13–21"; empty when the title says it all.
    public var detail: String
    /// One grey why, only when it is the point ("embeddings, which the CL slides assume"); empty
    /// most of the time. An exam-admission item shows its star from the item, not from here.
    public var why: String
    /// Planned length.
    public var minutes: Int
    /// A round's planned number of questions.
    @Column("question_count") public var questionCount: Int?
    /// A review's lecture and slides.
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("first_page") public var firstPage: Int?
    @Column("last_page") public var lastPage: Int?
    /// An exercise sheet, an exam-admission item or a seminar milestone.
    @Column("tracked_item_id") public var trackedItemID: TrackedItem.ID?
    /// A Read block's reading.
    @Column("reading_id") public var readingID: StudyReading.ID?
    /// The round or practice exam Start made.
    @Column("session_id") public var sessionID: StudySession.ID?
    /// What Start opens outside the app (an LMS quiz), when known.
    public var url: URL?
    /// Planned as an away day (phone-sized; the hero's tram glyph).
    @Column("is_away") public var isAway: Bool
    public var state: StudyBlockState
    /// Time counted toward "This week" for a block without a session (its minutes once done).
    @Column("spent_seconds") public var spentSeconds: Double
    @Column("started_at") public var startedAt: Date?
    @Column("done_at") public var doneAt: Date?
    /// `agent` (the planner) or `user` (the student asked the agent for it: `plan_adjust`).
    @Column("created_by") public var createdBy: Author
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        day: CalendarDay,
        sortOrder: Int = 0,
        kind: StudyBlockKind,
        courseID: Course.ID? = nil,
        courseIDs: [Course.ID] = [],
        title: String,
        detail: String = "",
        why: String = "",
        minutes: Int,
        questionCount: Int? = nil,
        lectureID: Lecture.ID? = nil,
        firstPage: Int? = nil,
        lastPage: Int? = nil,
        trackedItemID: TrackedItem.ID? = nil,
        readingID: StudyReading.ID? = nil,
        sessionID: StudySession.ID? = nil,
        url: URL? = nil,
        isAway: Bool = false,
        state: StudyBlockState = .planned,
        spentSeconds: Double = 0,
        startedAt: Date? = nil,
        doneAt: Date? = nil,
        createdBy: Author = .agent,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.day = day
        self.sortOrder = sortOrder
        self.kind = kind
        self.courseID = courseID
        self.courseIDs = courseIDs
        self.title = title
        self.detail = detail
        self.why = why
        self.minutes = minutes
        self.questionCount = questionCount
        self.lectureID = lectureID
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.trackedItemID = trackedItemID
        self.readingID = readingID
        self.sessionID = sessionID
        self.url = url
        self.isAway = isAway
        self.state = state
        self.spentSeconds = spentSeconds
        self.startedAt = startedAt
        self.doneAt = doneAt
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The courses the block is for (a round's `courseIDs`, else its course).
    public var courses: [Course.ID] {
        if !courseIDs.isEmpty { return courseIDs }
        return courseID.map { [$0] } ?? []
    }
}

// MARK: - Questions

/// One question of the bank, with its spaced-repetition card (one card per question, FSRS-5). Drafted
/// by Haiku from a lecture's topic (M4 study pass outputs), or the examiner's own from an old exam.
/// Never deleted while it has answers: `retired_at` hides it (a bad question, a vanished topic).
@Table("study_question")
public struct StudyQuestion: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID
    /// The lecture it is about (CASCADE); nil for an old exam's question not mapped to a lecture.
    @Column("lecture_id") public var lectureID: Lecture.ID?
    /// The M4 topic row (`annotation` ai · topic; SET NULL when the study pass re-runs: relinked by
    /// `TopicKey`).
    @Column("topic_id") public var topicID: Annotation.ID?
    /// The topic's title when it was drafted (mastery groups by `TopicKey(lectureID, topic)`).
    public var topic: String
    /// A reading's recall question (a Read block's round).
    @Column("reading_id") public var readingID: StudyReading.ID?
    public var format: StudyQuestionFormat
    public var pool: StudyQuestionPool
    /// A short name for result lists: "Three generations of virtualization" (≤ 6 words).
    public var title: String
    public var prompt: String
    /// A choice's options in display order.
    @Column(as: [String].JSONRepresentation.self) public var choices: [String]
    /// A choice's right option (0-based).
    @Column("correct_choice") public var correctChoice: Int?
    /// A label question's diagram.
    @Column(as: LabelDiagram?.JSONRepresentation.self) public var diagram: LabelDiagram?
    /// The reference answer Claude grades against (written formats); an old exam's model answer
    /// was written by Claude from the lectures.
    @Column("model_answer") public var modelAnswer: String
    /// Why, shown after an answer (AI, grey): "An unmodified guest OS is what full virtualization…".
    public var explanation: String
    /// Exam points (rounds ignore them).
    public var points: Int
    /// The slide shown beside the why.
    @Column("deck_id") public var deckID: Deck.ID?
    @Column("page_number") public var pageNumber: Int?
    /// The professor's exact words: an exact span of the line's `original_text` (so the screen
    /// can draw the line's corrections inside it as ~~old~~ new). Empty: no quote.
    public var quote: String
    @Column("transcript_segment_id") public var transcriptSegmentID: TranscriptSegment.ID?
    @Column("recording_id") public var recordingID: Recording.ID?
    /// Seconds on the recording's clock: the quote's first word (the chip, Space plays from here).
    @Column("quote_time") public var quoteTime: Double?
    /// Where the sentence ends (Space stops here).
    @Column("quote_end") public var quoteEnd: Double?
    public var origin: StudyQuestionOrigin
    /// An old exam's title ("Exam WS 2024/25"): the sheet's menu item.
    @Column("source_title") public var sourceTitle: String
    /// The question's number in the old exam.
    @Column("source_number") public var sourceNumber: Int?
    /// The old exam's PDF in the BlobStore.
    @Column("source_blob_sha256") public var sourceBlobSHA256: String?
    @Column("source_blob_path") public var sourceBlobPath: String?
    /// The drafting unit (`study_unit` stage `quiz`; SET NULL).
    @Column("study_unit_id") public var studyUnitID: StudyUnit.ID?
    @Column("api_call_id") public var apiCallID: APICall.ID?
    // FSRS card
    @Column("card_state") public var cardState: StudyCardState
    @Column("due_at") public var dueAt: Date?
    /// Days until recall falls to 90 % (FSRS S); nil while new.
    public var stability: Double?
    /// 1…10 (FSRS D); nil while new.
    public var difficulty: Double?
    public var reps: Int
    public var lapses: Int
    @Column("last_reviewed_at") public var lastReviewedAt: Date?
    @Column("retired_at") public var retiredAt: Date?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID,
        lectureID: Lecture.ID? = nil,
        topicID: Annotation.ID? = nil,
        topic: String = "",
        readingID: StudyReading.ID? = nil,
        format: StudyQuestionFormat,
        pool: StudyQuestionPool = .round,
        title: String = "",
        prompt: String,
        choices: [String] = [],
        correctChoice: Int? = nil,
        diagram: LabelDiagram? = nil,
        modelAnswer: String = "",
        explanation: String = "",
        points: Int = 1,
        deckID: Deck.ID? = nil,
        pageNumber: Int? = nil,
        quote: String = "",
        transcriptSegmentID: TranscriptSegment.ID? = nil,
        recordingID: Recording.ID? = nil,
        quoteTime: Double? = nil,
        quoteEnd: Double? = nil,
        origin: StudyQuestionOrigin = .generated,
        sourceTitle: String = "",
        sourceNumber: Int? = nil,
        sourceBlobSHA256: String? = nil,
        sourceBlobPath: String? = nil,
        studyUnitID: StudyUnit.ID? = nil,
        apiCallID: APICall.ID? = nil,
        cardState: StudyCardState = .new,
        dueAt: Date? = nil,
        stability: Double? = nil,
        difficulty: Double? = nil,
        reps: Int = 0,
        lapses: Int = 0,
        lastReviewedAt: Date? = nil,
        retiredAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.lectureID = lectureID
        self.topicID = topicID
        self.topic = topic
        self.readingID = readingID
        self.format = format
        self.pool = pool
        self.title = title
        self.prompt = prompt
        self.choices = choices
        self.correctChoice = correctChoice
        self.diagram = diagram
        self.modelAnswer = modelAnswer
        self.explanation = explanation
        self.points = points
        self.deckID = deckID
        self.pageNumber = pageNumber
        self.quote = quote
        self.transcriptSegmentID = transcriptSegmentID
        self.recordingID = recordingID
        self.quoteTime = quoteTime
        self.quoteEnd = quoteEnd
        self.origin = origin
        self.sourceTitle = sourceTitle
        self.sourceNumber = sourceNumber
        self.sourceBlobSHA256 = sourceBlobSHA256
        self.sourceBlobPath = sourceBlobPath
        self.studyUnitID = studyUnitID
        self.apiCallID = apiCallID
        self.cardState = cardState
        self.dueAt = dueAt
        self.stability = stability
        self.difficulty = difficulty
        self.reps = reps
        self.lapses = lapses
        self.lastReviewedAt = lastReviewedAt
        self.retiredAt = retiredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The topic it counts for (mastery, weakest topics).
    public var topicKey: TopicKey? { lectureID.map { TopicKey(lectureID: $0, title: topic) } }

    /// The old exam's PDF, when it came from one.
    public var sourceBlob: BlobRef? {
        guard let sha256 = sourceBlobSHA256, let path = sourceBlobPath else { return nil }
        return BlobRef(sha256: sha256, relativePath: path)
    }
}

/// One answer to one question: an append-only log (a round's answers, a submitted exam's). The
/// card on the question is updated from it once it is graded. An override keeps Claude's grade.
@Table("study_answer")
public struct StudyAnswer: StudyRecord {
    public let id: UUID
    @Column("question_id") public var questionID: StudyQuestion.ID
    /// The round or exam it was given in.
    @Column("session_id") public var sessionID: StudySession.ID?
    /// The question's course (studied time per course).
    @Column("course_id") public var courseID: Course.ID
    @Column(as: StudyResponse.JSONRepresentation.self) public var response: StudyResponse
    public var result: StudyAnswerResult
    /// 0…1 as it counts (the student's override when set); nil while pending.
    public var score: Double?
    /// Exam points as they count; nil in rounds and while pending.
    public var points: Double?
    /// Claude's verdict (≤ 40 words, grey with one sparkle): "Right. Name the rule too: …".
    public var note: String
    @Column("graded_by") public var gradedBy: StudyGrader
    public var grading: StudyGrading
    @Column("grading_attempts") public var gradingAttempts: Int
    @Column("grading_error") public var gradingError: String?
    /// Claude's own score, kept when the student overrides it.
    @Column("model_score") public var modelScore: Double?
    @Column("overridden_at") public var overriddenAt: Date?
    /// The FSRS rating applied to the card (1 Again … 4 Easy); nil until it is applied.
    public var rating: Int?
    /// Time spent on the question.
    public var seconds: Double
    @Column("answered_at") public var answeredAt: Date
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        questionID: StudyQuestion.ID,
        sessionID: StudySession.ID? = nil,
        courseID: Course.ID,
        response: StudyResponse,
        result: StudyAnswerResult,
        score: Double? = nil,
        points: Double? = nil,
        note: String = "",
        gradedBy: StudyGrader = .code,
        grading: StudyGrading = .none,
        gradingAttempts: Int = 0,
        gradingError: String? = nil,
        modelScore: Double? = nil,
        overriddenAt: Date? = nil,
        rating: Int? = nil,
        seconds: Double = 0,
        answeredAt: Date = Date(),
        apiCallID: APICall.ID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.questionID = questionID
        self.sessionID = sessionID
        self.courseID = courseID
        self.response = response
        self.result = result
        self.score = score
        self.points = points
        self.note = note
        self.gradedBy = gradedBy
        self.grading = grading
        self.gradingAttempts = gradingAttempts
        self.gradingError = gradingError
        self.modelScore = modelScore
        self.overriddenAt = overriddenAt
        self.rating = rating
        self.seconds = seconds
        self.answeredAt = answeredAt
        self.apiCallID = apiCallID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A written answer is given up on after this many failed grading calls.
    public static let maximumGradingAttempts = 3
}

// MARK: - Rounds and practice exams

/// A round of questions or a practice exam. A round asks `questionIDs[position]` (the coach
/// appends a missed question later in the round); a question is answered when an answer row of
/// this session exists for it at that position. An exam keeps its answers as drafts until Submit,
/// then they become `study_answer` rows; its clock is `activeSeconds` plus the time since
/// `resumedAt` (nil while paused).
@Table("study_session")
public struct StudySession: StudyRecord {
    public let id: UUID
    public var kind: StudySessionKind
    /// The course (nil for a round across courses).
    @Column("course_id") public var courseID: Course.ID?
    /// The plan block it was started from.
    @Column("block_id") public var blockID: StudyBlock.ID?
    /// The toolbar's subtitle start: "Data Centers", "Data Centers · CL".
    public var title: String
    @Column(as: StudyScope.JSONRepresentation.self) public var scope: StudyScope
    /// The questions in the order asked (an exam's order is fixed).
    @Column("question_ids", as: [StudyQuestion.ID].JSONRepresentation.self) public var questionIDs: [StudyQuestion.ID]
    /// The current question (0-based).
    public var position: Int
    /// An exam's length; nil for rounds and untimed exams.
    public var minutes: Int?
    /// An exam's total points.
    public var points: Int
    /// An exam's answers while written (saved as typed).
    @Column(as: [StudyDraft].JSONRepresentation.self) public var drafts: [StudyDraft]
    /// An exam's flagged questions.
    @Column(as: [StudyQuestion.ID].JSONRepresentation.self) public var flags: [StudyQuestion.ID]
    public var state: StudySessionState
    @Column("started_at") public var startedAt: Date
    /// The clock's last start; nil while paused or finished.
    @Column("resumed_at") public var resumedAt: Date?
    /// Clock time before `resumedAt`.
    @Column("active_seconds") public var activeSeconds: Double
    /// Submitted (exam) or ended (round).
    @Column("ended_at") public var endedAt: Date?
    /// An exam's points once graded (nil while any answer waits).
    @Column("score_points") public var scorePoints: Double?
    /// The exam this one retakes (same settings).
    @Column("retake_of") public var retakeOf: StudySession.ID?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: StudySessionKind,
        courseID: Course.ID? = nil,
        blockID: StudyBlock.ID? = nil,
        title: String = "",
        scope: StudyScope,
        questionIDs: [StudyQuestion.ID] = [],
        position: Int = 0,
        minutes: Int? = nil,
        points: Int = 0,
        drafts: [StudyDraft] = [],
        flags: [StudyQuestion.ID] = [],
        state: StudySessionState = .active,
        startedAt: Date = Date(),
        resumedAt: Date? = nil,
        activeSeconds: Double = 0,
        endedAt: Date? = nil,
        scorePoints: Double? = nil,
        retakeOf: StudySession.ID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.courseID = courseID
        self.blockID = blockID
        self.title = title
        self.scope = scope
        self.questionIDs = questionIDs
        self.position = position
        self.minutes = minutes
        self.points = points
        self.drafts = drafts
        self.flags = flags
        self.state = state
        self.startedAt = startedAt
        self.resumedAt = resumedAt
        self.activeSeconds = activeSeconds
        self.endedAt = endedAt
        self.scorePoints = scorePoints
        self.retakeOf = retakeOf
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Clock time so far (an exam's elapsed time; a round's length).
    public func elapsed(at now: Date) -> Double {
        activeSeconds + (resumedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// An exam's time left (nil: untimed or a round).
    public func remaining(at now: Date) -> Double? {
        minutes.map { max(0, Double($0) * 60 - elapsed(at: now)) }
    }

    /// The question asked now (nil past the end).
    public var currentQuestionID: StudyQuestion.ID? {
        questionIDs.indices.contains(position) ? questionIDs[position] : nil
    }

    /// An exam's draft for a question.
    public func draft(for questionID: StudyQuestion.ID) -> StudyResponse? {
        drafts.first { $0.questionID == questionID }?.response
    }
}

// MARK: - Reading list

/// One reading mapped to a lecture (research §4): a section of a book or paper, its slides, its
/// length. Drafted with the lecture's questions (from its further-reading rows and literature the
/// professor named) or added by the agent. A Read block opens it and ends in its recall questions.
@Table("study_reading")
public struct StudyReading: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID
    @Column("lecture_id") public var lectureID: Lecture.ID?
    /// The topic it fills (the topic's Read menu item); SET NULL like questions.
    @Column("topic_id") public var topicID: Annotation.ID?
    public var topic: String
    /// "OSTEP, Virtual Machine Monitors", "Popek & Goldberg, 1974".
    public var title: String
    /// "Appendix B", "§4.9".
    public var section: String
    /// "van Steen & Tanenbaum, 4th ed." (the popover).
    public var byline: String
    /// The slides it maps to.
    @Column("first_page") public var firstPage: Int?
    @Column("last_page") public var lastPage: Int?
    public var minutes: Int
    /// Where it opens (a verified further-reading URL, a free PDF).
    public var url: URL?
    /// A copy in the BlobStore (offline on away days).
    @Column("blob_sha256") public var blobSHA256: String?
    @Column("blob_path") public var blobPath: String?
    public var reason: ReadingReason
    /// Its trail for the source popover: the slide it is cited on, the lecture moment, the web page.
    @Column(as: [SourceRef].JSONRepresentation.self) public var sources: [SourceRef]
    /// The study pass's further-reading row it came from (SET NULL).
    @Column("source_annotation_id") public var sourceAnnotationID: Annotation.ID?
    @Column("sort_order") public var sortOrder: Int
    @Column("study_unit_id") public var studyUnitID: StudyUnit.ID?
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("done_at") public var doneAt: Date?
    @Column("hidden_at") public var hiddenAt: Date?
    @Column("created_by") public var createdBy: Author
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID,
        lectureID: Lecture.ID? = nil,
        topicID: Annotation.ID? = nil,
        topic: String = "",
        title: String,
        section: String = "",
        byline: String = "",
        firstPage: Int? = nil,
        lastPage: Int? = nil,
        minutes: Int,
        url: URL? = nil,
        blobSHA256: String? = nil,
        blobPath: String? = nil,
        reason: ReadingReason = .depth,
        sources: [SourceRef] = [],
        sourceAnnotationID: Annotation.ID? = nil,
        sortOrder: Int = 0,
        studyUnitID: StudyUnit.ID? = nil,
        apiCallID: APICall.ID? = nil,
        doneAt: Date? = nil,
        hiddenAt: Date? = nil,
        createdBy: Author = .agent,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.lectureID = lectureID
        self.topicID = topicID
        self.topic = topic
        self.title = title
        self.section = section
        self.byline = byline
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.minutes = minutes
        self.url = url
        self.blobSHA256 = blobSHA256
        self.blobPath = blobPath
        self.reason = reason
        self.sources = sources
        self.sourceAnnotationID = sourceAnnotationID
        self.sortOrder = sortOrder
        self.studyUnitID = studyUnitID
        self.apiCallID = apiCallID
        self.doneAt = doneAt
        self.hiddenAt = hiddenAt
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The topic it fills, when mapped.
    public var topicKey: TopicKey? {
        guard let lectureID, !topic.isEmpty else { return nil }
        return TopicKey(lectureID: lectureID, title: topic)
    }
}
