import Foundation
import StudyCore

/// The composer's local parse ("New deadline" in Calendar): one date (and time) mention, the
/// course by name, short name or token, the kind by its words, and the rest as the title.
/// Deterministic, no network, well under 5 ms (the caller caches the courses).
///
/// "DC sheet 1 due next Tuesday 12:00" on Fri 16 Oct 2026 → exercise "DC sheet 1", Cloud
/// Computing, Tue 20 Oct 12:00. "Klausur CL am 12.02." → exam "Klausur CL", all-day 12 Feb 2027.
/// Nil without a date.
public enum DeadlineParser {
    public static func parse(
        _ text: String,
        now: Date,
        courses: [Course],
        timeZone: TimeZone = DeadlinesModule.timeZone
    ) -> DeadlineDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let mentions = DateMentions.mentions(in: trimmed, reference: now, timeZone: timeZone)
        var dayMention: (day: CalendarDay, range: Range<String.Index>)?
        var timeMention: (minute: Int, range: Range<String.Index>)?
        for mention in mentions {
            switch mention.value {
            case .days(let days) where dayMention == nil:
                if let first = days.first { dayMention = (first, mention.range) }
            case .minutes(let minutes) where timeMention == nil:
                if let first = minutes.min() { timeMention = (min(first, 23 * 60 + 59), mention.range) }
            default:
                break
            }
        }
        guard let dayMention else { return nil }

        let due: Date
        let allDay: Bool
        if let timeMention {
            due = dayMention.day.date(minute: timeMention.minute, in: timeZone)
            allDay = false
        } else {
            due = dayMention.day.start(in: timeZone)
            allDay = true
        }
        let cut = [dayMention.range] + (timeMention.map { [$0.range] } ?? [])
        let title = Self.title(trimmed, removing: cut)
        let words = Set(TextFolding.words(trimmed))
        return DeadlineDraft(
            kind: kind(words),
            title: title.isEmpty ? trimmed : title,
            courseID: course(in: trimmed, courses: courses)?.id,
            dueAt: due,
            isAllDay: allDay
        )
    }

    // MARK: - Pieces

    /// exam ("exam", "Klausur", "Prüfung"), exercise ("sheet", "exercise", "assignment", "Blatt",
    /// "Übung"), else deadline.
    static func kind(_ words: Set<String>) -> TrackedItemKind {
        if !words.isDisjoint(with: examWords) || words.contains(where: { $0.hasPrefix("klausur") || $0.hasPrefix("prufung") }) {
            return .exam
        }
        if !words.isDisjoint(with: exerciseWords) || words.contains(where: { $0.hasPrefix("ubungsblatt") }) { return .exercise }
        return .deadline
    }

    static let examWords: Set<String> = ["exam", "exams", "klausur", "prufung", "midterm"]
    static let exerciseWords: Set<String> = [
        "sheet", "sheets", "exercise", "exercises", "assignment", "assignments", "homework", "blatt", "ubung", "ubungen", "aufgabe",
        "aufgaben", "ubungsblatt",
    ]

    /// Words around the date that are no part of the title.
    static let filler: Set<String> = [
        "due", "by", "on", "until", "till", "bis", "am", "fallig", "at", "um", "the", "is", "ist", "zum", "den", "dem", "spatestens",
        "deadline", "@",
    ]

    /// The course named by its name, short name or token ("DC", "CL", "SN"). Tokens are
    /// matched as written in capitals at word boundaries ("it" is a word, "SN" a course).
    static func course(in text: String, courses: [Course]) -> Course? {
        let folded = " " + TextFolding.words(text).joined(separator: " ") + " "
        let originalWords = Set(Self.originalWords(text))
        for course in courses {
            let name = TextFolding.words(course.name).joined(separator: " ")
            if !name.isEmpty, folded.contains(" \(name) ") { return course }
        }
        for course in courses {
            for token in tokens(of: course) where originalWords.contains(token) || originalWords.contains(token.lowercased()) && token.count >= 4 {
                return course
            }
        }
        return nil
    }

    /// Upper-case tokens a course goes by: its short name, its initials ("CL"), and for a
    /// subtitled name its main title's initials ("Sensor Networks: Field Work": "SN").
    static func tokens(of course: Course) -> [String] {
        var tokens: [String] = []
        let short = course.shortName.trimmingCharacters(in: .whitespaces)
        if !short.isEmpty { tokens.append(short.uppercased()) }
        let initials = TextFolding.words(course.name)
            .filter { !["and", "of", "the", "for", "in", "und", "der", "die", "das", "fur"].contains($0) }
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
        if initials.count >= 2 { tokens.append(initials) }
        if let colon = course.name.firstIndex(of: ":") {
            let title = TextFolding.words(String(course.name[..<colon]))
                .filter { !["and", "of", "the", "for", "in", "und", "der", "die", "das", "fur"].contains($0) }
                .compactMap(\.first)
                .map { String($0).uppercased() }
                .joined()
            if title.count >= 2, !tokens.contains(title) { tokens.append(title) }
        }
        return tokens
    }

    static func originalWords(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// `text` without the date and time phrases and the filler words next to them, first letter
    /// capitalized.
    static func title(_ text: String, removing ranges: [Range<String.Index>]) -> String {
        var pieces: [String] = []
        var cursor = text.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor {
            pieces.append(String(text[cursor..<range.lowerBound]))
            cursor = range.upperBound
        }
        pieces.append(String(text[cursor...]))
        let trimmedPieces = pieces.enumerated().map { index, piece in
            var words = piece.split(whereSeparator: \.isWhitespace).map(String.init)
            func isFiller(_ word: String) -> Bool {
                let core = word.trimmingCharacters(in: .punctuationCharacters)
                return core.isEmpty || filler.contains(TextFolding.fold(core))
            }
            // Before a removed phrase: "… due", "… bis zum"; after one: "at …", "um …".
            if index < pieces.count - 1 { while let last = words.last, isFiller(last) { words.removeLast() } }
            if index > 0 { while let first = words.first, isFiller(first) { words.removeFirst() } }
            return words.joined(separator: " ")
        }
        var title = trimmedPieces.filter { !$0.isEmpty }.joined(separator: " ")
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—.").union(.whitespaces))
        guard let first = title.first else { return "" }
        return first.uppercased() + title.dropFirst()
    }
}
