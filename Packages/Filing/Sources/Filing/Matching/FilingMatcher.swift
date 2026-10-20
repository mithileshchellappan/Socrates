import Foundation
import Processing
import StudyCore

/// Decides where a file goes: scores every course on the file's evidence, then picks the lecture
/// in the likely courses.
///
/// Course score (0…1) combines independent clues as 1 − Π(1 − wᵢ): the course name or a
/// lecturer's surname in the deck footer, on the title slide or in the PDF author; the file
/// name; the course's slides folder; a footer like that of decks already filed to the course;
/// glossary terms; for recordings, a session of the course overlapping the recording, or a
/// lecture of the course dated that day; for captures, the course they were captured for.
///
/// Lecture fit (0…1) within a course: a session (or lecture) with the file's number, the
/// session overlapping a recording, the session or lecture on the title slide's date, the next
/// session without slides, or a new lecture. A choice's confidence is score × fit.
public struct FilingMatcher: Sendable {
    /// At or above: filed without asking.
    public static let fileThreshold = 0.75
    /// Below this no course fits: ask for one.
    public static let courseThreshold = 0.45
    /// The two best destinations closer than this: ask.
    public static let tieMargin = 0.1
    /// A recording may start or end this much outside a session and still match it.
    public static let sessionSlack: TimeInterval = 15 * 60
    /// Share of a recording that must fall in a session (widened by the slack).
    public static let minimumOverlap = 0.5
    /// The lecture fit of a deck placed without a number or date (always below `fileThreshold`:
    /// reviewed, and the filing advisor decides).
    static let guessFit = 0.6
    /// Signals that say which lecture a deck is (a number, a date, a title), not only its course.
    static let lectureEvidence: Set<FilingSignal.Kind> = [.fileNumber, .slideNumber, .titleDate, .deckTitle, .knownFile]

    let library: FilingLibrary

    init(library: FilingLibrary) {
        self.library = library
    }

    /// The decision for `evidence`. With `destination` the user's choice wins (`source` manual);
    /// for a course destination the lecture is still picked from the evidence. `contested`
    /// lectures are not matched by a recording's day alone (several recordings in one drop
    /// claimed them).
    func decide(_ evidence: FileEvidence, destination: FilingDestination? = nil, contested: Set<Lecture.ID> = []) -> FilingDecision {
        if let destination {
            return decide(evidence, explicit: destination, contested: contested)
        }
        let scored = library.courses
            .map { course in (course: course, signals: courseSignals(course, evidence, contested: contested)) }
            .map { (course: $0.course, signals: $0.signals, score: Self.combine($0.signals)) }
            .sorted { $0.score > $1.score }

        guard let top = scored.first, top.score >= Self.courseThreshold else {
            let courses = scored.map { entry in
                FilingChoice(
                    place: FilingPlace(course: entry.course, isCourseOnly: true, destination: .course(entry.course.id), confidence: entry.score),
                    target: .new, signals: entry.signals, courseScore: entry.score
                )
            }
            return FilingDecision(verdict: .needsCourse, best: nil, alternatives: courses)
        }

        var candidates: [FilingChoice] = []
        for entry in scored where entry.score >= 0.2 || entry.course.id == top.course.id {
            let choices = lectureChoices(entry.course, evidence, contested: contested)
            for choice in choices.prefix(2) {
                var scaled = choice
                scaled.place.confidence = entry.score * choice.place.confidence
                scaled.signals = entry.signals + choice.signals
                scaled.courseScore = entry.score
                candidates.append(scaled)
            }
        }
        candidates.sort { $0.confidence > $1.confidence }
        guard let best = candidates.first else {
            return FilingDecision(verdict: .needsCourse, best: nil, alternatives: [])
        }
        let others = Array(candidates.dropFirst())
        let verdict: FilingDecision.Verdict
        if let second = others.first, best.confidence - second.confidence < Self.tieMargin {
            verdict = .ask
        } else if best.confidence >= Self.fileThreshold {
            verdict = .file
        } else {
            verdict = .review
        }
        return FilingDecision(verdict: verdict, best: best, alternatives: Array(others.prefix(3)))
    }

    private func decide(_ evidence: FileEvidence, explicit destination: FilingDestination, contested: Set<Lecture.ID>) -> FilingDecision {
        let choice: FilingChoice?
        switch destination {
        case .lecture(let id):
            choice = library.lecture(id).flatMap { info in
                library.course(info.lecture.courseID).map { lectureChoice(info, course: $0, fit: 1, signals: []) }
            }
        case .session(let id):
            choice = library.session(id).flatMap { session in
                library.course(session.courseID).map { sessionChoice(session, course: $0, fit: 1, signals: []) }
            }
        case .course(let id):
            choice = library.course(id).flatMap { lectureChoices($0, evidence, contested: contested).first }
        }
        guard var choice else { return FilingDecision(verdict: .needsCourse, best: nil, alternatives: []) }
        let name = choice.place.course.name
        // A deck dropped on a course whose lecture nothing names (no number, date or title):
        // the course is the student's, the lecture a guess, for review.
        let guessed: Bool
        if case .course = destination {
            guessed = evidence.kind == .deck && !choice.signals.contains { Self.lectureEvidence.contains($0.kind) }
        } else {
            guessed = false
        }
        choice.signals.insert(FilingSignal(kind: .user, evidence: name, weight: 1), at: 0)
        choice.courseScore = 1
        if case .course = destination {} else { choice.place.confidence = 1 }
        return FilingDecision(verdict: guessed ? .review : .file, best: choice, alternatives: [])
    }

    /// 1 − Π(1 − wᵢ)
    static func combine(_ signals: [FilingSignal]) -> Double {
        1 - signals.reduce(1.0) { $0 * (1 - min(max($1.weight, 0), 1)) }
    }

    // MARK: - Course evidence

    func courseSignals(_ course: Course, _ evidence: FileEvidence, contested: Set<Lecture.ID>) -> [FilingSignal] {
        var signals: [FilingSignal] = []
        let surnames = course.professors.compactMap(TextMatch.surname)

        // File name: "Data_Centers_03.pdf", "CL_L2.m4a".
        let base = (evidence.fileName as NSString).deletingPathExtension
        if TextMatch.contains(base, phrase: course.name) {
            signals.append(FilingSignal(kind: .deckTitle, evidence: evidence.fileName, weight: 0.4))
        } else if course.shortName.count >= 2, Numbering.words(base).contains(course.shortName) {
            signals.append(FilingSignal(kind: .deckTitle, evidence: evidence.fileName, weight: 0.3))
        }

        if let folder = course.slidesFolder, !folder.isEmpty, Self.isInside(evidence.url, folder: folder) {
            signals.append(FilingSignal(kind: .slidesFolder, evidence: folder, weight: 0.7))
        }

        if let deck = evidence.deck {
            if let line = deck.footer.first(where: { TextMatch.contains($0, phrase: course.name) }) {
                signals.append(FilingSignal(kind: .deckFooter, evidence: line, weight: 0.6))
            }
            if let line = deck.footer.first(where: { line in surnames.contains { TextMatch.contains(line, phrase: $0) } }) {
                signals.append(FilingSignal(kind: .deckFooter, evidence: line, weight: 0.45))
            }
            let title = TextMatch.normalize(deck.titleSlide.joined(separator: "\n"))
            if TextMatch.containsNormalized(title, phrase: course.name) {
                signals.append(FilingSignal(kind: .deckTitle, evidence: course.name, weight: 0.5))
            }
            if let surname = surnames.first(where: { TextMatch.containsNormalized(title, phrase: $0) }) {
                signals.append(FilingSignal(kind: .deckTitle, evidence: surname, weight: 0.3))
            }
            if let author = deck.pdfAuthor, surnames.contains(where: { TextMatch.contains(author, phrase: $0) }) {
                signals.append(FilingSignal(kind: .deckTitle, evidence: author, weight: 0.5))
            }
            if let pdfTitle = deck.pdfTitle, TextMatch.contains(pdfTitle, phrase: course.name) {
                signals.append(FilingSignal(kind: .deckTitle, evidence: pdfTitle, weight: 0.4))
            }
            let words = TextMatch.wordSet(deck.footer.joined(separator: " "))
            if !words.isEmpty, let similar = library.filedDecks[course.id]?
                .map({ (deck: $0, similarity: TextMatch.similarity(words, $0.footerWords)) })
                .max(by: { $0.similarity < $1.similarity }), similar.similarity >= 0.6 {
                signals.append(FilingSignal(kind: .deckFooter, evidence: similar.deck.fileName, weight: 0.6))
            }
            let terms = course.glossaryTerms.filter { $0.count >= 3 && TextMatch.containsNormalized(deck.sampledText, phrase: $0) }
            if terms.count >= 2 {
                signals.append(FilingSignal(kind: .glossary, evidence: terms.prefix(5).joined(separator: ", "), weight: min(0.3, 0.1 * Double(terms.count))))
            }
        }

        // The course chosen when it was captured: by id; an id this library does not have (an
        // iPhone capture before sync) by the course's name or short name.
        if let capture = evidence.capture {
            if let id = capture.courseID, library.course(id) != nil {
                if id == course.id {
                    signals.append(FilingSignal(kind: .capturedCourse, evidence: course.name, weight: 1))
                }
            } else if Self.names(course, capture) {
                signals.append(FilingSignal(kind: .capturedCourse, evidence: course.name, weight: 1))
            }
        }

        if let start = evidence.startedAt {
            let end = start.addingTimeInterval(max(0, evidence.duration ?? 0))
            if let (session, overlap) = bestSession(course.id, start: start, end: end) {
                signals.append(FilingSignal(
                    kind: .recordingStart, evidence: Self.stamp(session.startsAt, zone: library.zone), weight: min(0.95, 0.6 + 0.35 * overlap)
                ))
            } else if let info = sameDayLecture(course.id, start: start, contested: contested) {
                signals.append(FilingSignal(
                    kind: .sameDay, evidence: Self.stamp(info.lecture.heldAt ?? start, zone: library.zone), weight: 0.6
                ))
            }
        }
        return signals
    }

    /// The capture names `course`: its folded name, else its folded short name, is the course's.
    static func names(_ course: Course, _ capture: FileEvidence.CaptureEvidence) -> Bool {
        if let name = capture.courseName.map(TextMatch.normalize), !name.isEmpty, name == TextMatch.normalize(course.name) {
            return true
        }
        if let short = capture.courseShortName.map(TextMatch.normalize), !short.isEmpty,
           short == TextMatch.normalize(course.shortName) {
            return true
        }
        return false
    }

    // MARK: - Lecture within a course

    /// Destinations in `course`, best fit first; `place.confidence` holds the fit.
    func lectureChoices(_ course: Course, _ evidence: FileEvidence, contested: Set<Lecture.ID>) -> [FilingChoice] {
        let numbered = library.numberedSessions(courseID: course.id)
        let sessions = library.sessions(courseID: course.id)
        let lectures = library.lectures(courseID: course.id)
        var choices: [FilingChoice] = []

        let number: (value: Int, signal: FilingSignal)? = {
            if let value = evidence.fileNumber {
                return (value, FilingSignal(kind: .fileNumber, evidence: evidence.fileNumberEvidence ?? String(value), weight: 0.9))
            }
            if let value = evidence.deck?.slideNumber {
                return (value, FilingSignal(kind: .slideNumber, evidence: String(value), weight: 0.8))
            }
            return nil
        }()
        let date: (day: CalendarDay, signal: FilingSignal)? = evidence.deck?.titleDate.map {
            ($0, FilingSignal(kind: .titleDate, evidence: evidence.deck?.titleDateText ?? $0.rawValue, weight: 0.85))
        }

        // A recording or capture: the session it overlaps, else a lecture dated that day.
        var timed = false
        if let start = evidence.startedAt {
            let end = start.addingTimeInterval(max(0, evidence.duration ?? 0))
            if let (session, _) = bestSession(course.id, start: start, end: end) {
                let recorded = library.lecture(sessionID: session.id)?.hasRecording == true
                let signal = FilingSignal(kind: .weeklySlot, evidence: Self.stamp(session.startsAt, zone: library.zone), weight: 0.9)
                choices.append(sessionChoice(session, course: course, fit: recorded ? 0.9 : 1, signals: [signal]))
                timed = true
            } else if let info = sameDayLecture(course.id, start: start, contested: contested) {
                let signal = FilingSignal(kind: .sameDay, evidence: Self.stamp(start, zone: library.zone), weight: 0.6)
                choices.append(lectureChoice(info, course: course, fit: 1, signals: [signal]))
                timed = true
            }
        }

        if let number {
            let dayOK: (Date?) -> Bool = { when in
                guard let date, let when else { return true }
                return library.day(when) == date.day
            }
            let fit = timed ? 0.85 : 1
            if let session = numbered.first(where: { $0.number == number.value }) {
                choices.append(sessionChoice(session, course: course, fit: dayOK(session.startsAt) ? fit : 0.85, signals: [number.signal]))
            } else if let info = lectures.first(where: { $0.lecture.number == number.value }) {
                choices.append(lectureChoice(info, course: course, fit: dayOK(info.lecture.heldAt) ? fit : 0.85, signals: [number.signal]))
            } else {
                let session = date.flatMap { day in sessions.first { library.day($0.startsAt) == day.day } }
                if let session, library.lecture(sessionID: session.id) == nil {
                    var choice = sessionChoice(session, course: course, fit: 0.95, signals: [number.signal])
                    choice.target = .newLecture(number: number.value, heldAt: session.startsAt, sessionID: session.id)
                    choice.place.number = number.value
                    choices.append(choice)
                } else {
                    choices.append(newChoice(
                        course: course, number: number.value, heldAt: date?.day.start(in: library.zone) ?? evidence.startedAt,
                        wholeDay: date != nil, title: evidence.lectureTitle, fit: timed ? 0.8 : 0.95,
                        signals: [number.signal] + (date.map { [$0.signal] } ?? [])
                    ))
                }
            }
        }

        if let date {
            let fit = number == nil ? 1 : 0.85
            let onDay = sessions.filter { library.day($0.startsAt) == date.day }
            let session = onDay.first { library.lecture(sessionID: $0.id)?.hasDeck != true } ?? onDay.first
            if let session {
                choices.append(sessionChoice(session, course: course, fit: fit, signals: [date.signal]))
            } else if let info = lectures.first(where: { $0.lecture.heldAt.map(library.day) == date.day }) {
                choices.append(lectureChoice(info, course: course, fit: fit, signals: [date.signal]))
            } else if number == nil {
                choices.append(newChoice(
                    course: course, number: nil, heldAt: date.day.start(in: library.zone), wholeDay: true,
                    title: evidence.lectureTitle, fit: 0.95, signals: [date.signal]
                ))
            }
            // With a number and no session or lecture that day, the numbered new lecture above
            // already carries the date.
        }

        if choices.isEmpty {
            switch evidence.kind {
            case .deck:
                // No number, no date: a guess, always for review (the filing advisor looks again).
                // The earliest numbered session without slides that has begun (catching up a
                // course files L1, L2 in order), else the next one within 2 days; never a later
                // session without evidence.
                let open = numbered.filter { library.lecture(sessionID: $0.id)?.hasDeck != true }
                let soon = library.now.addingTimeInterval(2 * 86_400)
                let session = open.first { $0.startsAt <= library.now } ?? open.first { $0.startsAt > library.now && $0.startsAt <= soon }
                if let session {
                    let signal = FilingSignal(kind: .weeklySlot, evidence: Self.stamp(session.startsAt, zone: library.zone), weight: Self.guessFit)
                    choices.append(sessionChoice(session, course: course, fit: Self.guessFit, signals: [signal]))
                } else {
                    choices.append(newChoice(
                        course: course, number: nil, heldAt: nil, wholeDay: false, title: evidence.lectureTitle, fit: Self.guessFit, signals: []
                    ))
                }
            case .capture:
                if let id = evidence.capture?.lectureID, let info = library.lecture(id), info.lecture.courseID == course.id {
                    choices.append(lectureChoice(info, course: course, fit: 1, signals: []))
                } else {
                    var choice = newChoice(course: course, number: nil, heldAt: evidence.startedAt, wholeDay: false, title: "", fit: 1, signals: [])
                    choice.target = .new
                    choices.append(choice)
                }
            default:
                choices.append(newChoice(course: course, number: nil, heldAt: evidence.startedAt, wholeDay: false, title: "", fit: 0.8, signals: []))
            }
        }
        return Self.merge(choices)
    }

    /// One entry per destination: the best fit, all signals; agreeing clues raise the fit to 1.
    static func merge(_ choices: [FilingChoice]) -> [FilingChoice] {
        var merged: [FilingChoice] = []
        for choice in choices {
            if let index = merged.firstIndex(where: { $0.place.destination == choice.place.destination && $0.place.isNewLecture == choice.place.isNewLecture && !(choice.place.isNewLecture && $0.place.number != choice.place.number) }) {
                var existing = merged[index]
                existing.signals += choice.signals.filter { !existing.signals.contains($0) }
                existing.place.confidence = min(1, max(existing.place.confidence, choice.place.confidence) + 0.05)
                merged[index] = existing
            } else {
                merged.append(choice)
            }
        }
        return merged.sorted { $0.place.confidence > $1.place.confidence }
    }

    // MARK: - Building choices

    func sessionChoice(_ session: LectureSession, course: Course, fit: Double, signals: [FilingSignal]) -> FilingChoice {
        if let info = library.lecture(sessionID: session.id) {
            var choice = lectureChoice(info, course: course, fit: fit, signals: signals)
            choice.place.date = session.startsAt
            choice.place.isWholeDay = false
            choice.place.number = info.lecture.number ?? session.number
            choice.place.sessionKind = session.kind
            choice.place.sessionID = session.id
            if info.lecture.lectureSessionID != session.id {
                // Held in the session before it existed: the import links it (never a second lecture).
                choice.target = .session(session.id)
            }
            return choice
        }
        return FilingChoice(
            place: FilingPlace(
                course: course, sessionID: session.id, sessionKind: session.kind, number: session.number, date: session.startsAt,
                isNewLecture: true, destination: .session(session.id), confidence: fit
            ),
            target: .session(session.id), signals: signals, courseScore: 0
        )
    }

    func lectureChoice(_ info: FilingLibrary.LectureInfo, course: Course, fit: Double, signals: [FilingSignal]) -> FilingChoice {
        let lecture = info.lecture
        let session = lecture.lectureSessionID.flatMap(library.session)
        let date = session?.startsAt ?? lecture.heldAt
        return FilingChoice(
            place: FilingPlace(
                course: course, lectureID: lecture.id, sessionID: lecture.lectureSessionID, sessionKind: session?.kind,
                number: lecture.number ?? session?.number,
                date: date, isWholeDay: session == nil && LectureImporter.isWholeDay(lecture.heldAt, in: library.zone),
                title: lecture.title, destination: .lecture(lecture.id), confidence: fit
            ),
            target: .lecture(lecture.id), signals: signals, courseScore: 0
        )
    }

    func newChoice(course: Course, number: Int?, heldAt: Date?, wholeDay: Bool, title: String, fit: Double, signals: [FilingSignal]) -> FilingChoice {
        FilingChoice(
            place: FilingPlace(
                course: course, number: number, date: heldAt, isWholeDay: wholeDay, title: title, isNewLecture: true,
                destination: .course(course.id), confidence: fit
            ),
            target: .newLecture(number: number, heldAt: heldAt), signals: signals, courseScore: 0
        )
    }

    // MARK: - Time

    /// The course's session a recording from `start` to `end` falls in (≥ half of it, sessions
    /// widened by the slack), with the share.
    func bestSession(_ courseID: Course.ID, start: Date, end: Date) -> (LectureSession, Double)? {
        library.sessions(courseID: courseID)
            .map { ($0, Self.overlap(session: $0, start: start, end: end)) }
            .filter { $0.1 >= Self.minimumOverlap }
            .max { $0.1 < $1.1 }
    }

    static func overlap(session: LectureSession, start: Date, end: Date) -> Double {
        let low = session.startsAt.addingTimeInterval(-sessionSlack)
        let high = session.endsAt.addingTimeInterval(sessionSlack)
        let length = end.timeIntervalSince(start)
        guard length > 1 else { return start >= low && start <= session.endsAt ? 1 : 0 }
        let shared = min(end, high).timeIntervalSince(max(start, low))
        return max(0, shared) / length
    }

    /// A lecture of the course dated the recording's day, without a recording or session (a
    /// deck's title-slide date), unless several recordings in this drop claim it.
    func sameDayLecture(_ courseID: Course.ID, start: Date, contested: Set<Lecture.ID>) -> FilingLibrary.LectureInfo? {
        let day = library.day(start)
        return library.lectures(courseID: courseID).first { info in
            !info.hasRecording && info.lecture.lectureSessionID == nil && !contested.contains(info.lecture.id)
                && info.lecture.heldAt.map(library.day) == day
        }
    }

    static func stamp(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }

    static func isInside(_ url: URL, folder: String) -> Bool {
        let expanded = (folder as NSString).expandingTildeInPath
        let parent = URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let child = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(prefix)
    }
}
