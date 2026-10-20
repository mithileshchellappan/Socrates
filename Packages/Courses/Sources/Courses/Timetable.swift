import Foundation
import StudyCore

// Timetable files (a campus management system's `.ics`, one file per course unit: the lecture and its
// exercise come as separate files) read into what the timetable import proposes: weekly slots,
// one-off sessions and exam dates per course. Pure; `TimetableImporter` reads and writes the
// library.

// MARK: - Events

/// One event of a timetable file.
public struct TimetableEvent: Hashable, Sendable {
    /// A weekly series (`RRULE:FREQ=WEEKLY`).
    public struct Series: Hashable, Sendable {
        /// 1 = every week, 2 = every other week (counted from the first meeting).
        public var interval: Int
        /// ISO weekdays it meets on (1 = Monday).
        public var weekdays: [Int]
        /// Last day (inclusive), from UNTIL or COUNT.
        public var until: CalendarDay?
        /// EXDATE: days it does not meet (holiday weeks).
        public var excluded: [CalendarDay]
    }

    /// What an event is beyond a class meeting, from its DESCRIPTION.
    public enum Role: Hashable, Sendable {
        case meeting
        /// "Klausurtermin 1", "Klausurtermin 2 (E-Klausur)": the first or second exam date.
        case exam(attempt: Int)
        /// "… Klausureinsicht".
        case examReview
    }

    public var uid: String
    /// The file's name ("timetable 13.ics").
    public var file: String
    /// The course unit's number without "LV-" ("01-234-501"), when the title starts with one.
    public var number: String?
    /// SUMMARY without the number ("Übungen zu Data Centers").
    public var title: String
    /// From CATEGORIES (Vorlesung, Übung, Seminar/Mittelseminar, Tutorium), else the title.
    public var kind: SessionKind
    public var startsAt: Date
    public var endsAt: Date
    /// IANA time zone of the start.
    public var timeZone: String
    /// The full LOCATION ("B1-0101 (Room 101) Sample Street 1, Lecture Building (L | 01)").
    public var location: String
    /// DESCRIPTION ("Klausurtermin 1", "Initial Meeting"), empty when none.
    public var note: String
    public var series: Series?

    /// The short room: the location's first parenthesis ("Room 104").
    public var room: String { TimetableText.room(fromLocation: location) }
    public var role: Role { TimetableText.role(of: note) }
    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? TimetableText.zone }
}

public enum TimetableParser {
    /// Every timed VEVENT of `text` (all-day events are left out). Floating times are read in
    /// `timeZone`.
    public static func events(in text: String, file: String, timeZone: TimeZone = TimetableText.zone) -> [TimetableEvent] {
        ICSSlotImporter.events(in: text).compactMap { event($0, file: file, fallback: timeZone) }
    }

    static func event(_ event: ICSSlotImporter.Event, file: String, fallback: TimeZone) -> TimetableEvent? {
        guard let start = event["DTSTART"], let begin = ICSSlotImporter.dateTime(start, fallback: fallback) else { return nil }
        let zone = begin.zone
        var end = begin.date.addingTimeInterval(90 * 60)
        if let dtend = event["DTEND"].flatMap({ ICSSlotImporter.dateTime($0, fallback: zone) }) {
            end = dtend.date
        } else if let minutes = event["DURATION"].flatMap({ ICSSlotImporter.durationMinutes($0.value) }) {
            end = begin.date.addingTimeInterval(Double(minutes) * 60)
        }
        guard end > begin.date else { return nil }
        let summary = ICSSlotImporter.unescape(event["SUMMARY"]?.value ?? "")
        let (number, title) = TimetableText.splitNumber(summary)
        guard !title.isEmpty else { return nil }
        let categories = ICSSlotImporter.unescape(event["CATEGORIES"]?.value ?? "")
        let location = ICSSlotImporter.unescape(event["LOCATION"]?.value ?? "")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let uid = event["UID"]?.value.trimmingCharacters(in: .whitespaces) ?? ""

        var series: TimetableEvent.Series?
        if let rule = event["RRULE"].map({ ICSSlotImporter.recurrence($0.value) }), rule["FREQ"]?.uppercased() == "WEEKLY" {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let first = CalendarDay(begin.date, in: zone)
            let interval = min(max(1, Int(rule["INTERVAL"] ?? "1") ?? 1), 4)
            let weekdays = (rule["BYDAY"] ?? "")
                .split(separator: ",")
                .compactMap { ICSSlotImporter.weekdayCodes[String($0.suffix(2)).uppercased()] }
            var until = rule["UNTIL"].flatMap { ICSSlotImporter.untilDay($0, zone: zone) }
            if until == nil, let count = rule["COUNT"].flatMap({ Int($0) }), count > 0 {
                until = first.adding(days: 7 * interval * (count - 1) + 6)
            }
            series = TimetableEvent.Series(
                interval: interval,
                weekdays: weekdays.isEmpty ? [first.weekday] : weekdays,
                until: until,
                excluded: event["EXDATE"].map { excludedDays($0, zone: zone) } ?? []
            )
        }
        return TimetableEvent(
            uid: uid.isEmpty ? "\(summary)|\(start.value)" : uid,
            file: file,
            number: number,
            title: title,
            kind: ICSSlotImporter.kind(forSummary: categories.isEmpty ? title : categories),
            startsAt: begin.date,
            endsAt: end,
            timeZone: zone.identifier,
            location: location,
            note: ICSSlotImporter.unescape(event["DESCRIPTION"]?.value ?? ""),
            series: series
        )
    }

    /// "20261223T160000,20270106T160000" (or dates) as days in the series' zone.
    static func excludedDays(_ property: ICSSlotImporter.Property, zone fallback: TimeZone) -> [CalendarDay] {
        let zone = property.parameters["TZID"].flatMap(TimeZone.init(identifier:)) ?? fallback
        return property.value.split(separator: ",").compactMap { part in
            let value = part.trimmingCharacters(in: .whitespaces)
            if value.count == 8, let year = Int(value.prefix(4)), let month = Int(value.dropFirst(4).prefix(2)),
               let day = Int(value.suffix(2)) {
                return CalendarDay(year: year, month: month, day: day)
            }
            guard value.count >= 15,
                  let date = ICSSlotImporter.parseDateTime(String(value.prefix(15)), zone: value.hasSuffix("Z") ? .gmt : zone)
            else { return nil }
            return CalendarDay(date, in: fallback)
        }
    }
}

// MARK: - Words

/// How timetable titles, rooms and descriptions are read.
public enum TimetableText {
    /// The university's time zone (the profile's, else the system's): floating times are read in it.
    public static var zone: TimeZone { UniversityProfile.current.zone }

    /// "LV-01-234-501 Data Centers" → ("01-234-501", "Data Centers").
    static func splitNumber(_ summary: String) -> (String?, String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.wholeMatch(of: /(?:[A-Za-z]{1,4}-)?(\d+(?:-\d+)+)\s+(.+)/) {
            return (String(match.1), String(match.2).trimmingCharacters(in: .whitespaces))
        }
        return (nil, trimmed)
    }

    /// "B1-0101 (Room 101) Sample Street 1, …" → "Room 101"; without a parenthesis, the part
    /// before the first comma.
    public static func room(fromLocation location: String) -> String {
        if let match = location.firstMatch(of: /\(([^()]+)\)/) {
            return String(match.1).trimmingCharacters(in: .whitespaces)
        }
        return location.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func role(of note: String) -> TimetableEvent.Role {
        let text = fold(note)
        guard !text.isEmpty else { return .meeting }
        if text.contains("einsicht") || (text.contains("exam") && text.contains("review")) { return .examReview }
        // About the exam, not the exam: preparation, a mock exam, registration, a Q&A or office
        // hour, the discussion afterwards ("Klausurvorbereitung", "Probeklausur",
        // "Fragestunde zur Klausur", "Infoveranstaltung Prüfungsanmeldung").
        let aboutTheExam = ["vorbereitung", "probe", "mock", "anmeldung", "registration", "fragestunde", "sprechstunde", "nachbesprechung"]
        if aboutTheExam.contains(where: { text.contains($0) }) { return .meeting }
        guard text.contains("klausur") || text.contains("prufung") || text.contains("pruefung") || text.contains("exam") else {
            return .meeting
        }
        if text.contains("nachklausur") || text.contains("wiederholung") || text.contains("retake") || text.contains("resit") {
            return .exam(attempt: 2)
        }
        // "Klausurtermin 2", never the year of "Prüfungstermin 2027-02-09".
        if let match = text.firstMatch(of: /(?:termin|date|exam)\s*(\d)(?!\d)/), let attempt = Int(match.1), attempt > 0 {
            return .exam(attempt: attempt)
        }
        return .exam(attempt: 1)
    }

    /// Minutes after local midnight in `zone`.
    static func minute(of date: Date, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Lowercased, without diacritics, words separated by single spaces.
    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de"))
        let mapped = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// The sides of a bilingual title: "Computerlinguistik / Computational Linguistics".
    static func sides(_ title: String) -> [String] {
        let sides = title.components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return sides.isEmpty ? [title] : sides
    }

    /// `needle` appears in `haystack` as whole words (case and diacritics ignored).
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        let needle = fold(needle)
        guard !needle.isEmpty else { return false }
        return " \(fold(haystack)) ".contains(" \(needle) ")
    }

    static func isGerman(_ text: String) -> Bool {
        if text.contains(where: { "äöüÄÖÜß".contains($0) }) { return true }
        let words = Set(fold(text).split(separator: " ").map(String.init))
        let german: Set<String> = ["und", "fur", "der", "die", "das", "des", "zu", "zur", "zum", "im", "mit", "einfuhrung", "grundlagen", "ubungen"]
        return !words.isDisjoint(with: german)
    }

    /// The name of a new course: the English side of a bilingual title; for an exercise or
    /// tutorial without its lecture, without the lead-in ("Recitation in Robot Kinematics I" →
    /// "Robot Kinematics I").
    static func courseName(fromTitle title: String, kind: SessionKind) -> String {
        let sides = sides(title)
        let name = sides.last { !isGerman($0) } ?? sides.last ?? title
        guard kind == .exercise || kind == .tutorial else { return name }
        let words = name.split(separator: " ")
        let connectors: Set<String> = ["in", "zu", "zur", "zum", "for", "to", "on", "of"]
        for index in words.indices.prefix(3) where index > 0 && connectors.contains(words[index].lowercased()) {
            let rest = words[(index + 1)...]
            if !rest.isEmpty { return rest.joined(separator: " ") }
        }
        return name
    }

    /// "Klausurtermin 1 · 09.02.2027 10:00": the description and the date as the file states them.
    static func quote(note: String, at date: Date, zone: TimeZone) -> String {
        let stamp = date.formatted(Date.VerbatimFormatStyle(
            format: "\(day: .twoDigits).\(month: .twoDigits).\(year: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: zone,
            calendar: Calendar(identifier: .gregorian)
        ))
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? stamp : "\(note) · \(stamp)"
    }
}

// MARK: - Proposal

/// A weekly slot the import adds (one per weekday of a series).
public struct TimetableSlot: Hashable, Sendable, Identifiable {
    /// The series' UID and weekday.
    public var id: String
    public var kind: SessionKind
    public var weekday: Int
    public var startMinute: Int
    public var durationMinutes: Int
    public var weekInterval: Int
    /// The first meeting: fixes the week parity of a fortnightly slot.
    public var validFrom: CalendarDay
    public var validUntil: CalendarDay?
    public var room: String
    public var location: String
    public var timeZone: String
    /// Days it does not meet.
    public var excluded: [CalendarDay]

    public var endMinute: Int { startMinute + durationMinutes }

    /// The days it meets, ignoring the semester (nil without an end).
    func meetings() -> [CalendarDay]? {
        guard let until = validUntil else { return nil }
        var day = validFrom.adding(days: ((weekday - validFrom.weekday) % 7 + 7) % 7)
        var days: [CalendarDay] = []
        while day <= until {
            days.append(day)
            day = day.adding(days: 7 * max(1, weekInterval))
        }
        return days
    }

    /// True when the slot meets at `date` (its weekday, start, period and week parity).
    func meets(at date: Date) -> Bool {
        let zone = TimeZone(identifier: timeZone) ?? TimetableText.zone
        let day = CalendarDay(date, in: zone)
        guard day.weekday == weekday, TimetableText.minute(of: date, in: zone) == startMinute, validFrom <= day else { return false }
        if let validUntil, day > validUntil { return false }
        let first = validFrom.adding(days: ((weekday - validFrom.weekday) % 7 + 7) % 7)
        return (first.days(to: day) / 7) % max(1, weekInterval) == 0
    }
}

/// A one-off class meeting the import adds (a seminar's dates, an initial meeting).
public struct TimetableSession: Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: SessionKind
    public var startsAt: Date
    public var endsAt: Date
    public var room: String
    public var location: String
    public var timeZone: String
}

/// An exam date (or an exam review) the import puts into the deadline memory.
public struct TimetableItem: Hashable, Sendable, Identifiable {
    /// The first event's UID.
    public var id: String
    /// `.exam`, or `.event` for an exam review.
    public var kind: TrackedItemKind
    /// 1 = the first exam date, 2 = the second.
    public var attempt: Int
    /// "Data Centers exam", "Data Centers exam (2nd date)", "… exam review".
    public var title: String
    public var startsAt: Date
    public var endsAt: Date
    /// Short rooms ("Room 102", "Hall A"): several when the course is split across rooms.
    public var rooms: [String]
    public var locations: [String]
    public var timeZone: String
    /// The description and the date ("Klausurtermin 1 · 09.02.2027 10:00").
    public var quote: String
    /// The file it was read from.
    public var file: String

    /// The item's grey line: its rooms.
    public var details: String { rooms.joined(separator: " / ") }
    /// Where it takes place, in full (the calendar event's location).
    public var room: String { locations.joined(separator: " / ") }
}

/// One course of a dropped timetable: an existing course matched by name (or the one the files
/// were dropped on), or a course to add.
public struct TimetableCourse: Hashable, Sendable, Identifiable {
    /// The existing course's id, or the new course's (kept when it is added).
    public var id: UUID
    public var existing: Course?
    /// The existing course's name, or the cleaned title ("Robot Kinematics I").
    public var name: String
    public var language: String
    public var slots: [TimetableSlot]
    public var sessions: [TimetableSession]
    public var items: [TimetableItem]

    public var isNew: Bool { existing == nil }
    public var isEmpty: Bool { slots.isEmpty && sessions.isEmpty && items.isEmpty }
}

/// What a timetable drop would add, for the confirm sheet.
public struct TimetableImport: Hashable, Sendable, Identifiable {
    public var id = UUID()
    /// Existing courses first (library order), then new ones by name.
    public var courses: [TimetableCourse]
    /// The semester the courses meet in, with this import's changes.
    public var semester: Semester
    /// Not in the library yet.
    public var semesterIsNew: Bool
    /// Breaks this import adds or widens, as they will read (weeks every series skips).
    public var changedBreaks: [SemesterBreak]
    /// The lecture period grew (or the semester is new).
    public var periodChanged: Bool
    /// Colours of the library's courses (a new course takes the next free one).
    public var usedColors: [String]

    public var semesterChanged: Bool { semesterIsNew || periodChanged || !changedBreaks.isEmpty }
    /// Nothing to add (a timetable dropped again).
    public var isEmpty: Bool { courses.allSatisfy(\.isEmpty) }
    /// Existing courses are in; courses to add are the student's choice.
    public var defaultIncluded: Set<UUID> { Set(courses.filter { !$0.isNew }.map(\.id)) }

    /// The colour a course has, or gets when it is added with `included`.
    public func colorHex(for courseID: UUID, including included: Set<UUID>) -> String {
        if let existing = courses.first(where: { $0.id == courseID })?.existing { return existing.colorHex }
        var used = Set(usedColors.map { $0.lowercased() })
        var count = usedColors.count
        for course in courses where course.isNew && (included.contains(course.id) || course.id == courseID) {
            let color = CourseDraft.palette.first { !used.contains($0) } ?? CourseDraft.palette[count % CourseDraft.palette.count]
            if course.id == courseID { return color }
            used.insert(color)
            count += 1
        }
        return CourseDraft.palette[count % CourseDraft.palette.count]
    }
}

// MARK: - Grouping

/// Groups timetable events into courses and turns them into a proposal.
public enum Timetable {
    /// The events of one course unit (one title).
    struct Unit {
        var number: String?
        var title: String
        var kind: SessionKind
        var events: [TimetableEvent]
    }

    struct Group {
        var course: Course?
        var units: [Unit]
    }

    /// The proposal for `events` (deduplicated by UID already) against the library's courses.
    /// `forced`: the files were dropped on that course, so everything goes there.
    public static func proposal(
        events: [TimetableEvent],
        library: [Course],
        semesters: [Semester],
        forced: Course? = nil,
        now: Date = Date()
    ) -> TimetableImport {
        let groups = group(units(events), library: library, forced: forced)
        var courses = groups.map { course(from: $0) }
        let order = Dictionary(library.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        courses.sort { lhs, rhs in
            switch (lhs.existing, rhs.existing) {
            case let (left?, right?): return (order[left.id] ?? 0) < (order[right.id] ?? 0)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        // The semester: the one the first meeting falls in, else a new one from the series.
        let slots = courses.flatMap(\.slots)
        let firstDay = slots.map(\.validFrom).min()
            ?? events.map { CalendarDay($0.startsAt, in: $0.zone) }.min()
            ?? CalendarDay(now, in: TimetableText.zone)
        var semesterIsNew = false
        var semester: Semester
        if let containing = semesters.first(where: { $0.contains(firstDay) }) {
            semester = containing
        } else if slots.isEmpty {
            semester = Semester.current(among: semesters, on: now)
        } else {
            semesterIsNew = true
            let last = slots.compactMap(\.validUntil).max() ?? firstDay.adding(days: 7 * 15)
            semester = Semester(name: semesterName(starting: firstDay), lectureStart: firstDay, lectureEnd: last, timeZone: TimetableText.zone.identifier)
        }
        var periodChanged = semesterIsNew
        if !semesterIsNew, !slots.isEmpty {
            let start = min(semester.lectureStart, firstDay)
            let end = max(semester.lectureEnd, slots.compactMap(\.validUntil).max() ?? semester.lectureEnd)
            if start != semester.lectureStart || end != semester.lectureEnd {
                semester.lectureStart = start
                semester.lectureEnd = end
                periodChanged = true
            }
        }
        var changed: [SemesterBreak] = []
        for range in breakRanges(slots) {
            if let index = semester.breaks.firstIndex(where: { touches($0, range) }) {
                let widened = SemesterBreak(
                    name: semester.breaks[index].name,
                    first: min(semester.breaks[index].first, range.lowerBound),
                    last: max(semester.breaks[index].last, range.upperBound)
                )
                if widened != semester.breaks[index] {
                    semester.breaks[index] = widened
                    changed.removeAll { $0.name == widened.name }
                    changed.append(widened)
                }
            } else {
                let added = SemesterBreak(name: String(localized: "Break"), first: range.lowerBound, last: range.upperBound)
                semester.breaks.append(added)
                changed.append(added)
            }
        }
        semester.breaks.sort { $0.first < $1.first }

        return TimetableImport(
            courses: courses,
            semester: semester,
            semesterIsNew: semesterIsNew,
            changedBreaks: changed,
            periodChanged: periodChanged,
            usedColors: library.map(\.colorHex)
        )
    }

    // MARK: Units and groups

    static func units(_ events: [TimetableEvent]) -> [Unit] {
        var units: [Unit] = []
        var index: [String: Int] = [:]
        for event in events {
            let key = "\(event.number ?? "")|\(TimetableText.fold(event.title))"
            if let at = index[key] {
                units[at].events.append(event)
            } else {
                index[key] = units.count
                units.append(Unit(number: event.number, title: event.title, kind: event.kind, events: [event]))
            }
        }
        // A unit's kind: its meetings' most common kind (exam dates carry the lecture's).
        for at in units.indices {
            let meetings = units[at].events.filter { $0.role == .meeting }
            let kinds = (meetings.isEmpty ? units[at].events : meetings).map(\.kind)
            let counts = Dictionary(kinds.map { ($0, 1) }, uniquingKeysWith: +)
            if let best = counts.max(by: { $0.value == $1.value ? rank($0.key) > rank($1.key) : $0.value < $1.value }) {
                units[at].kind = best.key
            }
        }
        return units
    }

    static func rank(_ kind: SessionKind) -> Int {
        switch kind {
        case .lecture: 0
        case .seminar: 1
        case .exercise: 2
        case .tutorial: 3
        default: 4
        }
    }

    /// Lectures and seminars first, so exercises join them: an existing course whose name the
    /// title contains (either side of a bilingual title); else a unit already grouped whose
    /// title this one contains ("Übungen zu Data Centers" ⊃ "Data Centers"); else the
    /// lecture whose number is one less (LV-…-028 → …-029); else a course of its own.
    static func group(_ units: [Unit], library: [Course], forced: Course?) -> [Group] {
        if let forced { return units.isEmpty ? [] : [Group(course: forced, units: units)] }
        var groups: [Group] = []
        let ordered = units.sorted { (rank($0.kind), $0.title.count, $0.title) < (rank($1.kind), $1.title.count, $1.title) }
        for unit in ordered {
            if let course = match(unit, library: library) {
                if let at = groups.firstIndex(where: { $0.course?.id == course.id }) {
                    groups[at].units.append(unit)
                } else {
                    groups.append(Group(course: course, units: [unit]))
                }
            } else if let at = groups.firstIndex(where: { $0.units.contains { contains(unit, $0) } }) {
                groups[at].units.append(unit)
            } else if let at = groups.firstIndex(where: { $0.units.contains { pairs(unit, lecture: $0) } }) {
                groups[at].units.append(unit)
            } else {
                groups.append(Group(course: nil, units: [unit]))
            }
        }
        return groups
    }

    /// The library course this unit belongs to: its name inside the title (or a side of the
    /// title inside its name); the longest name wins.
    static func match(_ unit: Unit, library: [Course]) -> Course? {
        let sides = TimetableText.sides(unit.title)
        return library
            .filter { course in
                let name = course.name.trimmingCharacters(in: .whitespaces)
                guard TimetableText.fold(name).count >= 3 else { return false }
                return sides.contains { side in
                    TimetableText.contains(side, name)
                        || (TimetableText.fold(side).count >= 6 && TimetableText.contains(name, side))
                }
            }
            .max { $0.name.count < $1.name.count }
    }

    /// A side of `other`'s title inside a side of `unit`'s.
    static func contains(_ unit: Unit, _ other: Unit) -> Bool {
        let sides = TimetableText.sides(unit.title)
        return TimetableText.sides(other.title).contains { side in
            TimetableText.fold(side).count >= 6 && sides.contains { TimetableText.contains($0, side) }
        }
    }

    /// An exercise or tutorial numbered right after a lecture ("01-234-502" after "01-234-501").
    static func pairs(_ unit: Unit, lecture: Unit) -> Bool {
        guard unit.kind == .exercise || unit.kind == .tutorial, lecture.kind == .lecture,
              let number = unit.number, let lectureNumber = lecture.number else { return false }
        let parts = number.split(separator: "-")
        let lectureParts = lectureNumber.split(separator: "-")
        guard parts.count == lectureParts.count, parts.dropLast() == lectureParts.dropLast(),
              let last = parts.last.flatMap({ Int($0) }), let lectureLast = lectureParts.last.flatMap({ Int($0) })
        else { return false }
        return last == lectureLast + 1
    }

    // MARK: Courses

    static func course(from group: Group) -> TimetableCourse {
        let root = group.units.min { (rank($0.kind), $0.title.count) < (rank($1.kind), $1.title.count) }
        let name = group.course?.name ?? root.map { TimetableText.courseName(fromTitle: $0.title, kind: $0.kind) } ?? ""
        let language = group.course?.language ?? (TimetableText.isGerman(name) ? "de" : "en")
        let events = group.units.flatMap(\.events)

        var slots: [TimetableSlot] = []
        for event in events {
            guard let series = event.series else { continue }
            let zone = event.zone
            let first = CalendarDay(event.startsAt, in: zone)
            for weekday in series.weekdays {
                let slot = TimetableSlot(
                    id: "\(event.uid)|\(weekday)",
                    kind: event.kind,
                    weekday: weekday,
                    startMinute: TimetableText.minute(of: event.startsAt, in: zone),
                    durationMinutes: Int((event.endsAt.timeIntervalSince(event.startsAt) / 60).rounded()),
                    weekInterval: series.interval,
                    validFrom: first,
                    validUntil: series.until,
                    room: event.room,
                    location: event.location,
                    timeZone: zone.identifier,
                    excluded: series.excluded.filter { $0.weekday == weekday }.sorted()
                )
                if !slots.contains(where: { $0.kind == slot.kind && $0.weekday == slot.weekday && $0.startMinute == slot.startMinute }) {
                    slots.append(slot)
                }
            }
        }

        // Exam dates: one item per date and start (the same exam in two rooms is one), and a
        // plain event at an exam's start is that exam in another room.
        var items: [TimetableItem] = []
        let singles = events.filter { $0.series == nil }.sorted { ($0.startsAt, $0.uid) < ($1.startsAt, $1.uid) }
        for event in singles {
            let kind: TrackedItemKind
            let attempt: Int
            switch event.role {
            case .exam(let number):
                kind = .exam
                attempt = number
            case .examReview:
                kind = .event
                attempt = 0
            case .meeting:
                continue
            }
            if let at = items.firstIndex(where: { $0.kind == kind && $0.attempt == attempt && $0.startsAt == event.startsAt }) {
                if !event.room.isEmpty, !items[at].rooms.contains(event.room) {
                    items[at].rooms.append(event.room)
                    items[at].locations.append(event.location)
                }
                continue
            }
            items.append(TimetableItem(
                id: event.uid,
                kind: kind,
                attempt: attempt,
                title: itemTitle(course: name, kind: kind, attempt: attempt),
                startsAt: event.startsAt,
                endsAt: event.endsAt,
                rooms: event.room.isEmpty ? [] : [event.room],
                locations: event.location.isEmpty ? [] : [event.location],
                timeZone: event.timeZone,
                quote: TimetableText.quote(note: event.note, at: event.startsAt, zone: event.zone),
                file: event.file
            ))
        }

        var sessions: [TimetableSession] = []
        for event in singles where event.role == .meeting {
            if let at = items.firstIndex(where: { $0.kind == .exam && $0.startsAt == event.startsAt }) {
                if !event.room.isEmpty, !items[at].rooms.contains(event.room) {
                    items[at].rooms.append(event.room)
                    items[at].locations.append(event.location)
                }
                continue
            }
            // A meeting a series of the course plans anyway, or listed twice.
            if slots.contains(where: { $0.meets(at: event.startsAt) }) { continue }
            if sessions.contains(where: { $0.startsAt == event.startsAt }) { continue }
            sessions.append(TimetableSession(
                id: event.uid, kind: event.kind, startsAt: event.startsAt, endsAt: event.endsAt,
                room: event.room, location: event.location, timeZone: event.timeZone
            ))
        }

        slots.sort { (rank($0.kind), $0.weekday, $0.startMinute) < (rank($1.kind), $1.weekday, $1.startMinute) }
        items.sort { ($0.startsAt, $0.attempt) < ($1.startsAt, $1.attempt) }
        return TimetableCourse(
            id: group.course?.id ?? UUID(),
            existing: group.course,
            name: name,
            language: language,
            slots: slots,
            sessions: sessions,
            items: items
        )
    }

    /// "Data Centers exam", "Data Centers exam (2nd date)", "… exam review".
    static func itemTitle(course: String, kind: TrackedItemKind, attempt: Int) -> String {
        if kind != .exam { return String(localized: "\(course) exam review") }
        switch attempt {
        case ...1: return String(localized: "\(course) exam")
        case 2: return String(localized: "\(course) exam (2nd date)")
        case 3: return String(localized: "\(course) exam (3rd date)")
        default: return String(localized: "\(course) exam (\(attempt)th date)")
        }
    }

    // MARK: Semester

    /// "WS 2026/27" for a start from September to March, else "SS 2027".
    static func semesterName(starting day: CalendarDay) -> String {
        switch day.month {
        case 9...12: "WS \(day.year)/\(String(format: "%02d", (day.year + 1) % 100))"
        case 1...3: "WS \(day.year - 1)/\(String(format: "%02d", day.year % 100))"
        default: "SS \(day.year)"
        }
    }

    /// Weeks in which every series that would meet (at least two) skips its meeting: the
    /// university's holiday weeks, as day ranges (first to last skipped day of a run of weeks).
    static func breakRanges(_ slots: [TimetableSlot]) -> [ClosedRange<CalendarDay>] {
        var weeks: [CalendarDay: (meetings: Int, skipped: [CalendarDay])] = [:]
        for slot in slots {
            guard let meetings = slot.meetings() else { continue }
            let excluded = Set(slot.excluded)
            for day in meetings {
                let monday = day.adding(days: 1 - day.weekday)
                var week = weeks[monday] ?? (0, [])
                week.meetings += 1
                if excluded.contains(day) { week.skipped.append(day) }
                weeks[monday] = week
            }
        }
        let breakWeeks = weeks
            .filter { $0.value.meetings >= 2 && $0.value.skipped.count == $0.value.meetings }
            .sorted { $0.key < $1.key }
        var ranges: [ClosedRange<CalendarDay>] = []
        var previous: CalendarDay?
        for (monday, week) in breakWeeks {
            guard let first = week.skipped.min(), let last = week.skipped.max() else { continue }
            if let previous, previous.days(to: monday) == 7, let open = ranges.popLast() {
                ranges.append(open.lowerBound...max(open.upperBound, last))
            } else {
                ranges.append(first...last)
            }
            previous = monday
        }
        return ranges
    }

    /// The break overlaps the range or is at most a weekend away from it.
    static func touches(_ semesterBreak: SemesterBreak, _ range: ClosedRange<CalendarDay>) -> Bool {
        semesterBreak.first.adding(days: -3) <= range.upperBound && range.lowerBound <= semesterBreak.last.adding(days: 3)
    }
}
