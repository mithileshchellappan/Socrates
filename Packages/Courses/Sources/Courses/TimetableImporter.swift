import Foundation
import StudyCore

/// A dropped timetable file.
public struct TimetableFile: Sendable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    /// Reads an `.ics` file (UTF-8, else Latin-1); nil when it cannot be read.
    public static func read(_ url: URL) -> TimetableFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return TimetableFile(name: url.lastPathComponent, text: text)
    }
}

/// An exam date (or review) for the deadline memory, which the app writes (package `Deadlines`).
public struct TimetableItemDraft: Sendable {
    public var courseID: Course.ID
    public var kind: TrackedItemKind
    public var title: String
    /// The rooms ("Room 102 / Hall A").
    public var details: String
    public var dueAt: Date
    /// The full location.
    public var room: String
    /// The description and the date ("Klausurtermin 1 · 09.02.2027 10:00").
    public var quote: String
}

/// What the memory wrote for one draft.
public struct TimetableRecordedItem: Sendable {
    public var itemID: TrackedItem.ID
    /// The new source row (nil when the item had this source already).
    public var sourceID: TrackedItemSource.ID?

    public init(itemID: TrackedItem.ID, sourceID: TrackedItemSource.ID?) {
        self.itemID = itemID
        self.sourceID = sourceID
    }
}

/// Writes one exam draft into the deadline memory inside the import's transaction.
public typealias TimetableItemRecorder = @Sendable (TimetableItemDraft, Database) throws -> TimetableRecordedItem?

/// What an import wrote.
public struct TimetableImportResult: Sendable {
    public var createdCourses: [Course] = []
    /// Exam reviews (events): the app puts them in the calendar.
    public var eventItemIDs: [TrackedItem.ID] = []
}

/// The timetable import: dropped `.ics` files (the campus system, one file per course unit) →
/// a proposal without what the library has already (`prepare`) → after the student confirms,
/// courses, weekly slots, one-off sessions, the semester's holiday weeks and exam dates
/// (`apply`, one transaction). Dropping the same files again proposes nothing new.
public struct TimetableImporter: Sendable {
    public let services: StudyServices
    private let store: RecordStore

    public init(services: StudyServices) {
        self.services = services
        store = services.records
    }

    // MARK: - Prepare

    /// What `files` would add. `courseID`: the files were dropped on that course.
    public func prepare(_ files: [TimetableFile], courseID forced: Course.ID? = nil, now: Date = Date()) async throws -> TimetableImport {
        let events = Self.events(in: files)
        return try await services.database.read { db in
            let library = try Course.order(by: \.sortOrder).fetchAll(db)
            let semesters = try Semester.order(by: \.lectureStart).fetchAll(db)
            let forcedCourse = forced.flatMap { id in library.first { $0.id == id } }
            var proposal = Timetable.proposal(events: events, library: library, semesters: semesters, forced: forcedCourse, now: now)
            let sources = try TrackedItemSource.where { $0.kind.eq(SourceRef.Kind.timetable) }.fetchAll(db)
            var quotedItems: [TrackedItem.ID: TrackedItem] = [:]
            for source in sources where quotedItems[source.trackedItemID] == nil {
                quotedItems[source.trackedItemID] = try TrackedItem.find(source.trackedItemID).fetchOne(db)
            }
            for index in proposal.courses.indices {
                guard let course = proposal.courses[index].existing else { continue }
                let courseID = course.id
                let slots = try WeeklySlot.where { $0.courseID.eq(courseID) }.fetchAll(db)
                let sessions = try LectureSession.where { $0.courseID.eq(courseID) }.fetchAll(db)
                let quotes = Set(sources.filter { quotedItems[$0.trackedItemID]?.courseID == courseID }.map(\.quote))
                proposal.courses[index].slots.removeAll { slot in
                    slots.contains { $0.kind == slot.kind && $0.weekday == slot.weekday && $0.startMinute == slot.startMinute }
                }
                proposal.courses[index].sessions.removeAll { session in
                    sessions.contains { abs($0.startsAt.timeIntervalSince(session.startsAt)) < 60 }
                }
                proposal.courses[index].items.removeAll { quotes.contains($0.quote) }
            }
            proposal.courses.removeAll(where: \.isEmpty)
            return proposal
        }
    }

    /// The files' events, each UID once (the same course downloaded twice).
    public static func events(in files: [TimetableFile]) -> [TimetableEvent] {
        var seen = Set<String>()
        var events: [TimetableEvent] = []
        for file in files {
            for event in TimetableParser.events(in: file.text, file: file.name) where seen.insert(event.uid).inserted {
                events.append(event)
            }
        }
        return events
    }

    // MARK: - Apply

    /// Adds the proposal's existing courses' new rows and the courses in `included` (with their
    /// rows), widens the semester, cancels the meetings a series skips outside a break, and
    /// hands exam dates to `record` (the deadline memory); one transaction.
    @discardableResult
    public func apply(
        _ proposal: TimetableImport,
        including included: Set<UUID>,
        now: Date = Date(),
        record: TimetableItemRecorder? = nil
    ) async throws -> TimetableImportResult {
        let store = store
        let chosen = proposal.courses.filter { !$0.isNew || included.contains($0.id) }
        guard chosen.contains(where: { !$0.isEmpty }) else { return TimetableImportResult() }
        return try await services.database.write { db in
            var result = TimetableImportResult()
            var semester = proposal.semester
            if proposal.semesterChanged {
                semester = store.stamp(semester)
                try Semester.upsert { semester }.execute(db)
            }

            var written: [(courseID: Course.ID, slots: [(TimetableSlot, WeeklySlot.ID)], course: TimetableCourse)] = []
            for course in chosen {
                let courseID: Course.ID
                if let existing = course.existing {
                    courseID = existing.id
                } else {
                    let draft = CourseDraft(
                        name: course.name,
                        language: course.language,
                        colorHex: proposal.colorHex(for: course.id, including: included),
                        semesterID: semester.id
                    )
                    let created = try CourseLibrary.insert(draft, now: now, consentAt: now, store: store, db: db)
                    result.createdCourses.append(created)
                    courseID = created.id
                }
                var slotIDs: [(TimetableSlot, WeeklySlot.ID)] = []
                for slot in course.slots {
                    let row = store.stamp(WeeklySlot(
                        courseID: courseID, kind: slot.kind, weekday: slot.weekday, startMinute: slot.startMinute,
                        durationMinutes: slot.durationMinutes, room: slot.room, timeZone: slot.timeZone,
                        validFrom: slot.validFrom, validUntil: slot.validUntil, weekInterval: slot.weekInterval
                    ))
                    try WeeklySlot.upsert { row }.execute(db)
                    slotIDs.append((slot, row.id))
                }
                for session in course.sessions {
                    let row = store.stamp(LectureSession(
                        courseID: courseID, kind: session.kind, startsAt: session.startsAt, endsAt: session.endsAt,
                        room: session.room, editedAt: now
                    ))
                    try LectureSession.upsert { row }.execute(db)
                }
                written.append((courseID, slotIDs, course))
            }

            // Sessions: every course when the semester changed, else the courses touched.
            let replanned = proposal.semesterChanged ? try Course.all.fetchAll(db).map(\.id) : written.map(\.courseID)
            for courseID in replanned {
                try CourseSchedule.replan(courseID: courseID, now: now, planner: SessionPlanner(), store: store, db: db)
            }

            // A skipped meeting outside the semester's breaks is a cancelled session.
            for entry in written {
                var cancelled = false
                for (slot, slotID) in entry.slots {
                    let zone = TimeZone(identifier: slot.timeZone) ?? TimetableText.berlin
                    let skipped = Set(slot.excluded.filter { day in !semester.breaks.contains { $0.contains(day) } })
                    guard !skipped.isEmpty else { continue }
                    let sessions = try LectureSession.where { $0.weeklySlotID.eq(WeeklySlot.ID?.some(slotID)) }.fetchAll(db)
                    for var session in sessions where !session.isCancelled && skipped.contains(CalendarDay(session.startsAt, in: zone)) {
                        session.isCancelled = true
                        session.editedAt = now
                        let stamped = store.stamp(session)
                        try LectureSession.upsert { stamped }.execute(db)
                        cancelled = true
                    }
                }
                if cancelled {
                    try CourseSchedule.replan(courseID: entry.courseID, now: now, planner: SessionPlanner(), store: store, db: db)
                }
            }

            // Exam dates into the deadline memory; their source is the file.
            if let record {
                for entry in written {
                    for item in entry.course.items {
                        let draft = TimetableItemDraft(
                            courseID: entry.courseID, kind: item.kind, title: item.title, details: item.details,
                            dueAt: item.startsAt, room: item.room, quote: item.quote
                        )
                        guard let recorded = try record(draft, db) else { continue }
                        if let sourceID = recorded.sourceID, var source = try TrackedItemSource.find(sourceID).fetchOne(db) {
                            source.kind = .timetable
                            source.rfcMessageID = item.file
                            let stamped = store.stamp(source)
                            try TrackedItemSource.upsert { stamped }.execute(db)
                        }
                        if item.kind == .event { result.eventItemIDs.append(recorded.itemID) }
                    }
                }
            }
            CoursesLog.schedule.info(
                "Timetable import: \(written.count) course(s), \(result.createdCourses.count) new, \(written.map(\.slots.count).reduce(0, +)) slot(s)"
            )
            return result
        }
    }
}
