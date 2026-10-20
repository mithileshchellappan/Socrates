import Foundation
import SQLiteData

// Record types (schema v1 + later migrations). One struct per table; column names are snake_case.
// Conventions (see docs/schema.md):
//   - Primary keys are UUIDs stored as lowercase TEXT. Generate them in Swift (`UUID()`).
//   - Every table has `updated_at`; `RecordStore.save` stamps it.
//   - `page_number` is the 1-based page of a deck (what the user calls "slide 13").
//   - Times named `*_time` / `time` are seconds on a recording's clock (sample 0 = 0.0).
//   - Times named `*_at` are wall-clock dates.

/// A row with a UUID primary key and an `updated_at` timestamp.
public protocol StudyRecord: PrimaryKeyedTable, Identifiable, Hashable, Sendable
where PrimaryKey == UUID, ID == UUID, QueryOutput == Self {
    var updatedAt: Date { get set }
}

// MARK: - Courses & schedule

@Table("course")
public struct Course: StudyRecord {
    public let id: UUID
    public var name: String
    @Column("short_name") public var shortName: String
    @Column(as: [String].JSONRepresentation.self) public var professors: [String]
    /// BCP 47 language the course is taught in, e.g. "en".
    public var language: String
    /// Language of admin talk and mail, e.g. "de".
    @Column("admin_language") public var adminLanguage: String
    /// "#rrggbb"
    @Column("color_hex") public var colorHex: String
    /// Terms the transcriber and aligner must get right, one per line (see `glossaryTerms`).
    public var glossary: String
    /// Legacy free text (v1), never shown; `rules` is canonical since v4.
    @Column("exercise_rules") public var exerciseRules: String
    /// Legacy free text (v1), never shown; `rules` is canonical since v4.
    @Column("exam_rules") public var examRules: String
    /// When recording consent was recorded; nil = recording disabled for this course.
    @Column("recording_consent_at") public var recordingConsentAt: Date?
    /// Legacy (v1): copied into `mail_rule` rows by v5 and never read since; edit `MailRule`s.
    @Column("mail_rules", as: [MailRoutingRule].JSONRepresentation.self)
    public var mailRules: [MailRoutingRule]
    @Column("sort_order") public var sortOrder: Int
    /// v4: the semester the course runs in (lecture period and breaks for its sessions).
    @Column("semester_id") public var semesterID: Semester.ID?
    /// v4: exam admission, bonus points, exam form, … in display order.
    @Column(as: [CourseRule].JSONRepresentation.self) public var rules: [CourseRule]
    /// v4: whose voices recordings keep.
    @Column("recording_scope") public var recordingScope: RecordingScope
    /// v4: mirror this course's sessions to the "Socrates" calendar.
    @Column("shows_in_calendar") public var showsInCalendar: Bool
    /// v4: folder the course's slide PDFs are downloaded to (display path; smart import watches it).
    @Column("slides_folder") public var slidesFolder: String?
    /// v4: security-scoped bookmark of `slidesFolder` (needed on iOS/iPadOS).
    @Column("slides_folder_bookmark") public var slidesFolderBookmark: Data?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date
    /// v12 (mc): credit points (ECTS / LP), a course fact the agent sets (`set_course_credits`);
    /// nil = not known yet (the coach assumes the profile's default and the agent asks).
    public var credits: Double?
    /// v12 (mc): the module's own self-study hours when its files state them (DC: 120 h); wins
    /// over credits × hours per credit − class hours.
    @Column("self_study_hours") public var selfStudyHours: Double?

    public init(
        id: UUID = UUID(),
        name: String,
        shortName: String = "",
        professors: [String] = [],
        language: String = "en",
        adminLanguage: String = "de",
        colorHex: String = "#0a84ff",
        glossary: String = "",
        exerciseRules: String = "",
        examRules: String = "",
        recordingConsentAt: Date? = nil,
        mailRules: [MailRoutingRule] = [],
        sortOrder: Int = 0,
        semesterID: Semester.ID? = nil,
        rules: [CourseRule] = [],
        recordingScope: RecordingScope = .lecturer,
        showsInCalendar: Bool = true,
        slidesFolder: String? = nil,
        slidesFolderBookmark: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        credits: Double? = nil,
        selfStudyHours: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.professors = professors
        self.language = language
        self.adminLanguage = adminLanguage
        self.colorHex = colorHex
        self.glossary = glossary
        self.exerciseRules = exerciseRules
        self.examRules = examRules
        self.recordingConsentAt = recordingConsentAt
        self.mailRules = mailRules
        self.sortOrder = sortOrder
        self.semesterID = semesterID
        self.rules = rules
        self.recordingScope = recordingScope
        self.showsInCalendar = showsInCalendar
        self.slidesFolder = slidesFolder
        self.slidesFolderBookmark = slidesFolderBookmark
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.credits = credits
        self.selfStudyHours = selfStudyHours
    }

    /// Glossary entries (lines, or comma/semicolon separated, as Transcription and Alignment read
    /// them). Setting writes one term per line; commas and semicolons inside a term become spaces.
    public var glossaryTerms: [String] {
        get {
            glossary
                .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            glossary = newValue
                .map { $0.replacing(",", with: " ").replacing(";", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    /// Recording is allowed only once consent is recorded (PRD trust rule).
    public var recordsLectures: Bool { recordingConsentAt != nil }
}

/// A recurring weekly class slot, e.g. "Mon 12:15–13:45, Room 101".
@Table("weekly_slot")
public struct WeeklySlot: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID
    public var kind: SessionKind
    /// ISO 8601 weekday: 1 = Monday … 7 = Sunday.
    public var weekday: Int
    /// Minutes after local midnight in `timeZone`.
    @Column("start_minute") public var startMinute: Int
    @Column("duration_minutes") public var durationMinutes: Int
    public var room: String
    /// IANA time zone identifier.
    @Column("time_zone") public var timeZone: String
    /// First day the slot applies (inclusive); nil = the semester's lecture start. Also fixes the
    /// week parity when `weekInterval` > 1.
    @Column("valid_from") public var validFrom: CalendarDay?
    /// Last day the slot applies (inclusive); nil = the semester's lecture end.
    @Column("valid_until") public var validUntil: CalendarDay?
    /// v4: 1 = every week, 2 = every other week ("14-täglich").
    @Column("week_interval") public var weekInterval: Int
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID,
        kind: SessionKind = .lecture,
        weekday: Int,
        startMinute: Int,
        durationMinutes: Int = 90,
        room: String = "",
        timeZone: String = UniversityProfile.current.zone.identifier,
        validFrom: CalendarDay? = nil,
        validUntil: CalendarDay? = nil,
        weekInterval: Int = 1,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.kind = kind
        self.weekday = weekday
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.room = room
        self.timeZone = timeZone
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.weekInterval = weekInterval
        self.updatedAt = updatedAt
    }

    /// Minutes after local midnight when the slot ends.
    public var endMinute: Int { startMinute + durationMinutes }
}

/// One concrete class meeting (from a weekly slot or one-off), mirrored to the calendar.
@Table("lecture_session")
public struct LectureSession: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID
    @Column("weekly_slot_id") public var weeklySlotID: WeeklySlot.ID?
    public var kind: SessionKind
    @Column("starts_at") public var startsAt: Date
    @Column("ends_at") public var endsAt: Date
    public var room: String
    @Column("is_cancelled") public var isCancelled: Bool
    /// EventKit `calendarItemExternalIdentifier` in the "Socrates" calendar.
    @Column("calendar_event_id") public var calendarEventID: String?
    /// v4: ordinal among the course's non-cancelled sessions of this kind ("Lecture 3"), kept up to
    /// date by session planning; nil when unknown.
    public var number: Int?
    /// v4: when the user changed this session by hand (moved, cancelled, one-off); planning from
    /// weekly slots never overwrites or deletes an edited session. Nil = generated.
    @Column("edited_at") public var editedAt: Date?
    /// v4: when the calendar event last matched this row (`updatedAt` at that moment). The event
    /// needs writing when this is nil or older than `updatedAt`.
    @Column("calendar_synced_at") public var calendarSyncedAt: Date?
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID,
        weeklySlotID: WeeklySlot.ID? = nil,
        kind: SessionKind = .lecture,
        startsAt: Date,
        endsAt: Date,
        room: String = "",
        isCancelled: Bool = false,
        calendarEventID: String? = nil,
        number: Int? = nil,
        editedAt: Date? = nil,
        calendarSyncedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.weeklySlotID = weeklySlotID
        self.kind = kind
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.room = room
        self.isCancelled = isCancelled
        self.calendarEventID = calendarEventID
        self.number = number
        self.editedAt = editedAt
        self.calendarSyncedAt = calendarSyncedAt
        self.updatedAt = updatedAt
    }

    /// True when the calendar event must be written (or removed, when cancelled).
    public var needsCalendarSync: Bool { calendarSyncedAt.map { $0 < updatedAt } ?? true }
}

// MARK: - Slides

/// An imported slide PDF. The file lives in the BlobStore.
@Table("deck")
public struct Deck: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID?
    public var title: String
    /// Original file name at import.
    @Column("file_name") public var fileName: String
    @Column("blob_sha256") public var blobSHA256: String
    /// Path relative to the BlobStore root.
    @Column("blob_path") public var blobPath: String
    @Column("page_count") public var pageCount: Int
    @Column("imported_at") public var importedAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID? = nil,
        title: String = "",
        fileName: String = "",
        blobSHA256: String = "",
        blobPath: String = "",
        pageCount: Int = 0,
        importedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.fileName = fileName
        self.blobSHA256 = blobSHA256
        self.blobPath = blobPath
        self.pageCount = pageCount
        self.importedAt = importedAt
        self.updatedAt = updatedAt
    }

    public var blob: BlobRef? {
        blobSHA256.isEmpty ? nil : BlobRef(sha256: blobSHA256, relativePath: blobPath)
    }
}

@Table("deck_page")
public struct DeckPage: StudyRecord {
    public let id: UUID
    @Column("deck_id") public var deckID: Deck.ID
    /// 1-based.
    @Column("page_number") public var pageNumber: Int
    /// PDF page label if it differs from the number.
    public var label: String
    /// Extracted slide text.
    public var text: String
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        deckID: Deck.ID,
        pageNumber: Int,
        label: String = "",
        text: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.deckID = deckID
        self.pageNumber = pageNumber
        self.label = label
        self.text = text
        self.updatedAt = updatedAt
    }
}

// MARK: - Lectures

@Table("lecture")
public struct Lecture: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID
    @Column("lecture_session_id") public var lectureSessionID: LectureSession.ID?
    /// Lecture number within the course ("Lecture 2"), if known.
    public var number: Int?
    public var title: String
    @Column("held_at") public var heldAt: Date?
    /// Main spoken language, BCP 47.
    public var language: String
    /// v4: when the student finished reviewing it; nil = not reviewed (Today offers it).
    @Column("reviewed_at") public var reviewedAt: Date?
    /// v4: where review left off, seconds on the lecture's (first) recording clock.
    @Column("review_position") public var reviewPosition: Double?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID,
        lectureSessionID: LectureSession.ID? = nil,
        number: Int? = nil,
        title: String = "",
        heldAt: Date? = nil,
        language: String = "",
        reviewedAt: Date? = nil,
        reviewPosition: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.lectureSessionID = lectureSessionID
        self.number = number
        self.title = title
        self.heldAt = heldAt
        self.language = language
        self.reviewedAt = reviewedAt
        self.reviewPosition = reviewPosition
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Which deck pages a lecture covered (many-to-many lecture <-> deck pages).
///
/// Used at two granularities: a coarse span ("slides 1–37 of deck X", no times) and, from the
/// aligner, one span per slide visit with `startTime`/`endTime` on the recording clock.
/// A timed span without pages is an off-slide stretch (admin talk, Q&A, a break).
@Table("lecture_deck_span")
public struct LectureDeckSpan: StudyRecord {
    public let id: UUID
    @Column("lecture_id") public var lectureID: Lecture.ID
    @Column("deck_id") public var deckID: Deck.ID
    /// Nil (with `lastPage`) for an off-slide stretch.
    @Column("first_page") public var firstPage: Int?
    @Column("last_page") public var lastPage: Int?
    @Column("recording_id") public var recordingID: Recording.ID?
    @Column("start_time") public var startTime: Double?
    @Column("end_time") public var endTime: Double?
    public var source: SpanSource
    /// 0…1
    public var confidence: Double
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        lectureID: Lecture.ID,
        deckID: Deck.ID,
        firstPage: Int?,
        lastPage: Int?,
        recordingID: Recording.ID? = nil,
        startTime: Double? = nil,
        endTime: Double? = nil,
        source: SpanSource,
        confidence: Double = 1,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.lectureID = lectureID
        self.deckID = deckID
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.recordingID = recordingID
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    /// True for a timed stretch that is on no slide.
    public var isOffSlide: Bool { firstPage == nil && startTime != nil }

    /// True for an aligner span (has times), false for a coarse page range.
    public var isTimed: Bool { startTime != nil }
}

// MARK: - Recording

/// One continuous recording clock. Audio is split into `RecordingSegment` files.
@Table("recording")
public struct Recording: StudyRecord {
    public let id: UUID
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("course_id") public var courseID: Course.ID?
    public var source: RecordingSource
    public var state: RecordingState
    /// Wall clock at sample 0.
    @Column("started_at") public var startedAt: Date
    /// `mach_absolute_time()` at sample 0, when recorded live.
    @Column("host_time_at_start") public var hostTimeAtStart: Int64?
    @Column("sample_rate") public var sampleRate: Double
    @Column("channel_count") public var channelCount: Int
    /// Seconds.
    public var duration: Double
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        lectureID: Lecture.ID? = nil,
        courseID: Course.ID? = nil,
        source: RecordingSource = .mac,
        state: RecordingState = .recording,
        startedAt: Date = Date(),
        hostTimeAtStart: Int64? = nil,
        sampleRate: Double = 48_000,
        channelCount: Int = 1,
        duration: Double = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.lectureID = lectureID
        self.courseID = courseID
        self.source = source
        self.state = state
        self.startedAt = startedAt
        self.hostTimeAtStart = hostTimeAtStart
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

/// One audio file of a recording, placed on the recording clock by `startSample`.
@Table("recording_segment")
public struct RecordingSegment: StudyRecord {
    public let id: UUID
    @Column("recording_id") public var recordingID: Recording.ID
    /// 0-based order within the recording.
    public var sequence: Int
    /// Frame offset of this file's first sample on the recording clock.
    @Column("start_sample") public var startSample: Int64
    @Column("frame_count") public var frameCount: Int64
    /// Empty until the finished file is moved into the BlobStore.
    @Column("blob_sha256") public var blobSHA256: String
    @Column("blob_path") public var blobPath: String
    @Column("byte_count") public var byteCount: Int64
    /// File extension / container, e.g. "caf", "m4a", "wav".
    @Column("file_format") public var fileFormat: String
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        recordingID: Recording.ID,
        sequence: Int,
        startSample: Int64 = 0,
        frameCount: Int64 = 0,
        blobSHA256: String = "",
        blobPath: String = "",
        byteCount: Int64 = 0,
        fileFormat: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.recordingID = recordingID
        self.sequence = sequence
        self.startSample = startSample
        self.frameCount = frameCount
        self.blobSHA256 = blobSHA256
        self.blobPath = blobPath
        self.byteCount = byteCount
        self.fileFormat = fileFormat
        self.updatedAt = updatedAt
    }

    public var blob: BlobRef? {
        blobSHA256.isEmpty ? nil : BlobRef(sha256: blobSHA256, relativePath: blobPath, byteCount: byteCount)
    }
}

/// A live event (slide stamp, flag) on the recording clock.
@Table("slide_event")
public struct SlideEvent: StudyRecord {
    public let id: UUID
    @Column("recording_id") public var recordingID: Recording.ID?
    @Column("lecture_id") public var lectureID: Lecture.ID?
    public var kind: SlideEventKind
    @Column("deck_id") public var deckID: Deck.ID?
    /// 1-based page shown after the event (nil for flags).
    @Column("page_number") public var pageNumber: Int?
    /// Frame position on the recording clock.
    @Column("sample_time") public var sampleTime: Int64?
    /// `mach_absolute_time()` when the event happened.
    @Column("host_time") public var hostTime: Int64?
    @Column("wall_clock") public var wallClock: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        recordingID: Recording.ID? = nil,
        lectureID: Lecture.ID? = nil,
        kind: SlideEventKind,
        deckID: Deck.ID? = nil,
        pageNumber: Int? = nil,
        sampleTime: Int64? = nil,
        hostTime: Int64? = nil,
        wallClock: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.recordingID = recordingID
        self.lectureID = lectureID
        self.kind = kind
        self.deckID = deckID
        self.pageNumber = pageNumber
        self.sampleTime = sampleTime
        self.hostTime = hostTime
        self.wallClock = wallClock
        self.updatedAt = updatedAt
    }
}

// MARK: - Transcript

@Table("transcript_segment")
public struct TranscriptSegment: StudyRecord {
    public let id: UUID
    @Column("recording_id") public var recordingID: Recording.ID
    @Column("lecture_id") public var lectureID: Lecture.ID?
    /// Seconds on the recording clock.
    @Column("start_time") public var startTime: Double
    @Column("end_time") public var endTime: Double
    /// Current text: `TranscriptPatch.apply(patches, to: originalText)` (v8). Change it only
    /// through `withPatches`.
    public var text: String
    /// Text as first transcribed; never overwritten.
    @Column("original_text") public var originalText: String
    /// BCP 47, e.g. "de", "en".
    public var lang: String
    public var confidence: Double?
    /// Incremented each time corrections change `text`.
    public var revision: Int
    @Column(as: [TranscriptWord]?.JSONRepresentation.self) public var words: [TranscriptWord]?
    @Column("updated_at") public var updatedAt: Date
    /// v8: the corrections, as patches on `originalText` (nil = none). docs/plan-m4.md §2.
    @Column(as: [TranscriptPatch]?.JSONRepresentation.self) public var patches: [TranscriptPatch]?

    public init(
        id: UUID = UUID(),
        recordingID: Recording.ID,
        lectureID: Lecture.ID? = nil,
        startTime: Double,
        endTime: Double,
        text: String,
        originalText: String? = nil,
        lang: String = "",
        confidence: Double? = nil,
        revision: Int = 0,
        words: [TranscriptWord]? = nil,
        updatedAt: Date = Date(),
        patches: [TranscriptPatch]? = nil
    ) {
        self.id = id
        self.recordingID = recordingID
        self.lectureID = lectureID
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.originalText = originalText ?? text
        self.lang = lang
        self.confidence = confidence
        self.revision = revision
        self.words = words
        self.updatedAt = updatedAt
        self.patches = patches
    }
}

// MARK: - Notes & annotations

/// A rich note anchored to (lecture, slide, audio time).
@Table("note")
public struct Note: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID?
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("deck_id") public var deckID: Deck.ID?
    @Column("page_number") public var pageNumber: Int?
    @Column("recording_id") public var recordingID: Recording.ID?
    /// Seconds on the recording clock.
    @Column("audio_time") public var audioTime: Double?
    /// Note body as JSON blocks; format owned by the notes editor.
    @Column("blocks") public var blocksJSON: String
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID? = nil,
        lectureID: Lecture.ID? = nil,
        deckID: Deck.ID? = nil,
        pageNumber: Int? = nil,
        recordingID: Recording.ID? = nil,
        audioTime: Double? = nil,
        blocksJSON: String = "[]",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.lectureID = lectureID
        self.deckID = deckID
        self.pageNumber = pageNumber
        self.recordingID = recordingID
        self.audioTime = audioTime
        self.blocksJSON = blocksJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A marker on a slide or transcript span in one of the You / Professor / AI layers.
///
/// Target: set the columns that apply — a slide (`deckID` + `pageNumber`), a time range on a
/// recording (`recordingID` + `startTime`/`endTime`), and/or a transcript segment.
/// M4 (v8): what the study pass writes and the student's pins, see `Values+M4.swift` and
/// docs/plan-m4.md §2. Hidden rows (`hiddenAt`) are gone from every surface.
@Table("annotation")
public struct Annotation: StudyRecord {
    public let id: UUID
    @Column("lecture_id") public var lectureID: Lecture.ID?
    public var layer: AnnotationLayer
    public var kind: AnnotationKind
    @Column("deck_id") public var deckID: Deck.ID?
    @Column("page_number") public var pageNumber: Int?
    @Column("recording_id") public var recordingID: Recording.ID?
    @Column("start_time") public var startTime: Double?
    @Column("end_time") public var endTime: Double?
    @Column("transcript_segment_id") public var transcriptSegmentID: TranscriptSegment.ID?
    public var body: String
    @Column(as: [SourceRef].JSONRepresentation.self) public var citations: [SourceRef]
    /// The model call that produced this (AI layer).
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date
    /// v8: the study pass unit that wrote it (re-running the unit replaces its rows; deleting it
    /// cascades). Nil for the student's own pins.
    @Column("study_unit_id") public var studyUnitID: StudyUnit.ID?
    /// v8: what a `not_on_slides` item is about.
    public var category: SaidInClassCategory?
    /// v8: a second line, e.g. a further reading's byline ("Barham et al. · SOSP 2003").
    public var detail: String?
    /// v8: an exact span of the page's text the pin sits beside (professor items).
    @Column("anchor_text") public var anchorText: String?
    /// v8: a hand-placed pin's position on the page, 0…1 from the top left.
    @Column("anchor_x") public var anchorX: Double?
    @Column("anchor_y") public var anchorY: Double?
    /// v8: the last slide of a range (topics: `pageNumber…lastPage`).
    @Column("last_page") public var lastPage: Int?
    /// v8: the student hid it (AI and professor items).
    @Column("hidden_at") public var hiddenAt: Date?

    public init(
        id: UUID = UUID(),
        lectureID: Lecture.ID? = nil,
        layer: AnnotationLayer,
        kind: AnnotationKind,
        deckID: Deck.ID? = nil,
        pageNumber: Int? = nil,
        recordingID: Recording.ID? = nil,
        startTime: Double? = nil,
        endTime: Double? = nil,
        transcriptSegmentID: TranscriptSegment.ID? = nil,
        body: String = "",
        citations: [SourceRef] = [],
        apiCallID: APICall.ID? = nil,
        studyUnitID: StudyUnit.ID? = nil,
        category: SaidInClassCategory? = nil,
        detail: String? = nil,
        anchorText: String? = nil,
        anchorX: Double? = nil,
        anchorY: Double? = nil,
        lastPage: Int? = nil,
        hiddenAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.lectureID = lectureID
        self.layer = layer
        self.kind = kind
        self.deckID = deckID
        self.pageNumber = pageNumber
        self.recordingID = recordingID
        self.startTime = startTime
        self.endTime = endTime
        self.transcriptSegmentID = transcriptSegmentID
        self.body = body
        self.citations = citations
        self.apiCallID = apiCallID
        self.studyUnitID = studyUnitID
        self.category = category
        self.detail = detail
        self.anchorText = anchorText
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.lastPage = lastPage
        self.hiddenAt = hiddenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Deadlines & exercises

@Table("tracked_item")
public struct TrackedItem: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID?
    public var kind: TrackedItemKind
    public var title: String
    public var details: String
    @Column("due_at") public var dueAt: Date?
    @Column("is_all_day") public var isAllDay: Bool
    public var status: TrackedItemStatus
    /// Exact quote the item was extracted from (the first source's; every source's quote is on
    /// its `TrackedItemSource` row).
    @Column("source_quote") public var sourceQuote: String
    /// Legacy (v1) pointers; since v5 provenance lives in `tracked_item_source` rows.
    @Column("source_refs", as: [SourceRef].JSONRepresentation.self) public var sourceRefs: [SourceRef]
    /// EventKit `calendarItemExternalIdentifier` in the "Socrates" calendar.
    @Column("calendar_event_id") public var calendarEventID: String?
    @Column("created_by") public var createdBy: Author
    /// v5: the lecture session a room change or cancellation is about (or a deadline is tied to).
    @Column("lecture_session_id") public var lectureSessionID: LectureSession.ID?
    /// v5: the new room of a room change; where an exam or event takes place.
    public var room: String?
    /// v5: the item belongs in the "Socrates" calendar (set automatically for verified
    /// deadlines, by Add to Calendar otherwise); the calendar mirror writes events for open items
    /// with a due date where this is true and removes the others.
    @Column("in_calendar") public var inCalendar: Bool
    /// v5: when the calendar event last matched this row (`updatedAt` at that moment).
    @Column("calendar_synced_at") public var calendarSyncedAt: Date?
    /// v6: why it matters beyond its date (exam admission, bonus points); nil for most items.
    public var relevance: ItemRelevance?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID? = nil,
        kind: TrackedItemKind,
        title: String,
        details: String = "",
        dueAt: Date? = nil,
        isAllDay: Bool = false,
        status: TrackedItemStatus = .open,
        sourceQuote: String = "",
        sourceRefs: [SourceRef] = [],
        calendarEventID: String? = nil,
        createdBy: Author = .agent,
        lectureSessionID: LectureSession.ID? = nil,
        room: String? = nil,
        inCalendar: Bool = false,
        calendarSyncedAt: Date? = nil,
        relevance: ItemRelevance? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.kind = kind
        self.title = title
        self.details = details
        self.dueAt = dueAt
        self.isAllDay = isAllDay
        self.status = status
        self.sourceQuote = sourceQuote
        self.sourceRefs = sourceRefs
        self.calendarEventID = calendarEventID
        self.createdBy = createdBy
        self.lectureSessionID = lectureSessionID
        self.room = room
        self.inCalendar = inCalendar
        self.calendarSyncedAt = calendarSyncedAt
        self.relevance = relevance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when the calendar event must be written or removed.
    public var needsCalendarSync: Bool { calendarSyncedAt.map { $0 < updatedAt } ?? true }

    /// An event belongs in the calendar for this item.
    public var wantsCalendarEvent: Bool { inCalendar && status == .open && dueAt != nil }
}

// MARK: - Bookkeeping

/// One Claude API call: usage and cost. Written by ClaudeKit for every call.
@Table("api_call")
public struct APICall: StudyRecord {
    public let id: UUID
    public var model: String
    /// What the call was for, e.g. "correction", "routing", "tutor".
    public var purpose: String
    /// Anthropic `request-id` response header.
    @Column("request_id") public var requestID: String?
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("input_tokens") public var inputTokens: Int
    @Column("output_tokens") public var outputTokens: Int
    @Column("cache_read_tokens") public var cacheReadTokens: Int
    @Column("cache_write_tokens") public var cacheWriteTokens: Int
    @Column("cost_usd") public var costUSD: Double
    @Column("duration_ms") public var durationMs: Int
    @Column("stop_reason") public var stopReason: String?
    public var error: String?
    /// v7: `subscription` for Claude Code calls (`cost_usd` notional); nil for the Messages API
    /// and rows written before v7.
    public var billing: CallBilling?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        model: String,
        purpose: String,
        requestID: String? = nil,
        lectureID: Lecture.ID? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        costUSD: Double = 0,
        durationMs: Int = 0,
        stopReason: String? = nil,
        error: String? = nil,
        billing: CallBilling? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.model = model
        self.purpose = purpose
        self.requestID = requestID
        self.lectureID = lectureID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
        self.durationMs = durationMs
        self.stopReason = stopReason
        self.error = error
        self.billing = billing
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A unit of background processing (transcribe, align, ...), with determinate progress.
@Table("job")
public struct Job: StudyRecord {
    public let id: UUID
    public var stage: JobStage
    public var state: JobState
    /// 0…1, of `phase` when set, else of the stage.
    public var progress: Double
    /// Set while a running job prepares (e.g. downloads a model); nil for the stage's own work.
    public var phase: JobPhase?
    public var error: String?
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("recording_id") public var recordingID: Recording.ID?
    public var attempt: Int
    @Column("created_at") public var createdAt: Date
    @Column("started_at") public var startedAt: Date?
    @Column("finished_at") public var finishedAt: Date?
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        stage: JobStage,
        state: JobState = .queued,
        progress: Double = 0,
        phase: JobPhase? = nil,
        error: String? = nil,
        lectureID: Lecture.ID? = nil,
        recordingID: Recording.ID? = nil,
        attempt: Int = 0,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.stage = stage
        self.state = state
        self.progress = progress
        self.phase = phase
        self.error = error
        self.lectureID = lectureID
        self.recordingID = recordingID
        self.attempt = attempt
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
    }
}
