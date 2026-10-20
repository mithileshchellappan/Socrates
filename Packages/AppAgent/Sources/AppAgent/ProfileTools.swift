import Agent
import ClaudeKit
import Courses
import Deadlines
import Foundation
import StudyCore

/// oss: the student's university as data, managed through the agent (PRD "Manage it through the
/// agent, not UI"): `set_profile` records the university's name, the city, the programme, the
/// time zone, the learning platform, the hours of work per credit and the current semester's name
/// and lecture period, ONLY when the student tells it in chat. One change of the log
/// (`ChangeLog.Request.profile`, kind `profile`): the profile row (`UniversityProfileRecord`, which
/// becomes the current profile once the write commits) and the semester (saved and every course
/// replanned, `CourseSchedule.saveSemester`), with Undo.
extension WriteTools {
    var setProfile: AgentTool {
        AgentTool(
            tool: .custom(
                name: "set_profile",
                description: """
                    Records the student's university profile and semester ONLY when the student tells you (quote: \
                    their words): the university's name, the city, the programme as it reads before "student" \
                    ("history bachelor's"), the time zone (IANA, "Europe/Lisbon": dates are read and written in \
                    it), the learning platform's name (mail from it about a course routes by a "<platform> course is" \
                    rule), the hours of work per credit, and the current semester's name and lecture period (its \
                    sessions are planned again). Only the fields you give change (null: unchanged). Undo puts the old \
                    values back.
                    """,
                inputSchema: Schema.object([
                    "university": Schema.optionalString("The university's name; null: unchanged."),
                    "city": Schema.optionalString("The city the student studies in; null: unchanged."),
                    "program": Schema.optionalString("The programme as it reads before \"student\"; null: unchanged."),
                    "time_zone": Schema.optionalString("IANA time zone (\"Europe/Lisbon\"); null: unchanged."),
                    "learning_platform": Schema.optionalString("The learning platform's name as its mails write it; null: unchanged."),
                    "hours_per_credit": Schema.nullable(PlanTools.number),
                    "semester_name": Schema.optionalString("The current semester's name; null: unchanged."),
                    "lecture_start": Schema.optionalString("First day of lectures, YYYY-MM-DD; null: unchanged."),
                    "lecture_end": Schema.optionalString("Last day of lectures, YYYY-MM-DD; null: unchanged."),
                    "quote": quoteProperty,
                ])
            ),
            effect: .verifiedWrite
        ) { call, context in
            let checked: VerifiedQuote
            switch try await studentAsked(call, context: context) {
            case .success(let value): checked = value
            case .failure(let refusal): return .error(refusal.message)
            }
            let stored = try await services.database.read { db in try UniversityProfileRecord.profile(in: db) }
            var profile = stored
            if let university = call.text("university") { profile.name = university }
            if let city = call.text("city") { profile.city = city }
            if let program = call.text("program") { profile.program = program }
            if let platform = call.text("learning_platform") { profile.learningPlatform = platform }
            if let zone = call.text("time_zone") {
                guard let known = TimeZone(identifier: zone) else { return .error("time_zone must be an IANA time zone such as Europe/Lisbon.") }
                profile.timeZone = known.identifier
            }
            if let hours = call.number("hours_per_credit") {
                guard hours >= 1, hours <= 60 else { return .error("hours_per_credit must be between 1 and 60.") }
                guard PlanTools.states(hours, in: checked.quote) else { return .error("The quote must state \(CoachCatalogNumber.text(hours)).") }
                profile.hoursPerCredit = hours
            }

            let current = try await SemesterRepository(store: services.records).current(on: context.now)
            var semester = current
            if let name = call.text("semester_name") { semester.name = name }
            if let text = call.text("lecture_start") {
                guard let day = CalendarDay(rawValue: text) else { return .error("lecture_start must be YYYY-MM-DD.") }
                semester.lectureStart = day
            }
            if let text = call.text("lecture_end") {
                guard let day = CalendarDay(rawValue: text) else { return .error("lecture_end must be YYYY-MM-DD.") }
                semester.lectureEnd = day
            }
            guard semester.lectureStart <= semester.lectureEnd else { return .error("lecture_start must not be after lecture_end.") }
            if call.text("time_zone") != nil { semester.timeZone = profile.timeZone }
            let semesterChange: Semester? = SemesterValues(semester) == SemesterValues(current) ? nil : semester

            guard profile != stored || semesterChange != nil else {
                return .error("Give at least one field that differs from the profile and semester now.")
            }
            let outcome = try await applyAsked(.profile(profile, semester: semesterChange), checked: checked, context: context)
            switch outcome {
            case .applied(let change):
                return .json(["applied": true, "cite": .string(change.citation.marker), "title": .string(change.title), "summary": .string(change.summary)])
            case .unchanged(let text):
                return .json(["applied": false, "note": .string(text)])
            case .conflict(let text), .refused(let text):
                return .error(text)
            }
        }
    }
}

extension ChangeLog {
    /// `set_profile` inside the caller's transaction: the profile row and the semester (saved,
    /// every course replanned) with their change row; `before` holds what they were.
    static func setProfile(
        _ profile: UniversityProfile, semester: Semester?, quote: String, confidence: Double, origin: Origin, db: Database,
        store: RecordStore, now: Date
    ) throws -> Outcome {
        let existed = try UniversityProfileRecord.stored(in: db) != nil
        let old = try UniversityProfileRecord.profile(in: db)
        var oldSemester: Semester?
        if let semester {
            guard let row = try Semester.find(semester.id).fetchOne(db) else { return .refused("Unknown semester.") }
            oldSemester = row
        }
        let semesterChanged = semester.map { new in oldSemester.map { SemesterValues($0) != SemesterValues(new) } ?? true } ?? false
        guard profile != old || semesterChanged else { return .unchanged("The profile and the semester say that already.") }
        if profile != old { try UniversityProfileRecord.save(profile, at: now, db: db) }
        if let semester, semesterChanged { try CourseSchedule.saveSemester(semester, now: now, store: store, db: db) }

        let newSemester = semesterChanged ? semester : nil
        let summary = profileSummary(old: old, new: profile, semester: newSemester)
        var change = AgentChange(
            kind: .profile, targetTable: .profile, targetID: UniversityProfileRecord.rowID, title: "University profile",
            summary: String(summary.prefix(AgentChange.summaryLimit)),
            before: AgentChangeValues(exists: existed, universityProfile: old, semester: semesterChanged ? oldSemester.map(SemesterValues.init) : nil),
            after: AgentChangeValues(exists: true, universityProfile: profile, semester: newSemester.map(SemesterValues.init)),
            sourceKind: origin.sourceKind, taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: confidence,
            model: origin.model, apiCallID: origin.apiCallID, appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        return .applied(change)
    }

    /// Undo of `set_profile`: the profile as it was while the library's is still the one the
    /// change wrote, and the semester as it was while it still has the values the change wrote
    /// (then every course is replanned).
    static func undoProfile(_ change: AgentChange, db: Database, store: RecordStore, now: Date) throws {
        guard let before = change.before, let after = change.after else { return }
        if let old = before.universityProfile, let new = after.universityProfile, try UniversityProfileRecord.profile(in: db) == new {
            try UniversityProfileRecord.save(old, at: now, db: db)
        }
        if let old = before.semester, let new = after.semester,
           let row = try Semester.find(new.id).fetchOne(db), SemesterValues(row) == new {
            try CourseSchedule.saveSemester(old.semester(updatedAt: now), now: now, store: store, db: db)
        }
    }

    /// "Time zone Europe/Lisbon · 30 h per credit · Semester 2026/27, 5 Oct – 29 Jan": what changed.
    static func profileSummary(old: UniversityProfile, new: UniversityProfile, semester: Semester?) -> String {
        var parts: [String] = []
        if new.name != old.name { parts.append(new.name.isEmpty ? "No university" : new.name) }
        if new.city != old.city { parts.append(new.city.isEmpty ? "No city" : "City \(new.city)") }
        if new.program != old.program { parts.append(new.program.isEmpty ? "No programme" : "Programme \(new.program)") }
        if new.timeZone != old.timeZone { parts.append("Time zone \(new.zone.identifier)") }
        if new.learningPlatform != old.learningPlatform {
            parts.append(new.learningPlatform.isEmpty ? "No learning platform" : "Learning platform \(new.learningPlatform)")
        }
        if new.hoursPerCredit != old.hoursPerCredit { parts.append("\(CoachCatalogNumber.text(new.hoursPerCredit)) h per credit") }
        if let semester {
            let zone = semester.zone
            let first = ChangeSummary.day(semester.lectureStart.start(in: zone), timeZone: zone)
            let last = ChangeSummary.day(semester.lectureEnd.start(in: zone), timeZone: zone)
            parts.append("\(semester.name.isEmpty ? "Semester" : semester.name), \(first) – \(last)")
        }
        return parts.isEmpty ? "Profile set" : parts.joined(separator: " · ")
    }
}
