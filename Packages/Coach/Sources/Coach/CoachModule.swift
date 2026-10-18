import Deadlines
import Foundation
import os
import StudyCore

/// The study coach's engine (docs/plan-coach.md §4, §5.1): `CoachEngine` (`StudyCoaching`),
/// `PlanEngine`, `Scheduler`, `RoundBuilder`, `PracticeExamBuilder`, `QuestionDrafter`,
/// `AnswerGrader`, `OldExamReader`, `ProfileItems` and `CoachCatalog`. Logic only, no SwiftUI.
public enum CoachModule {
    public static let moduleName = "Coach"
    static let log = Log.logger(category: "coach")

    /// The plan's days and every date the coach writes are the university's time zone.
    public static let timeZone = DeadlinesModule.timeZone

    /// `api_call.purpose` of the coach's calls (billing `subscription`).
    public enum Purpose {
        /// Haiku 5.5 drafts a lecture's questions and readings (`question_draft` tasks).
        public static let draft = "coach.draft"
        /// Opus 5.5, effort medium, grades written answers.
        public static let grade = "coach.grade"
        /// Opus 5.5, effort medium, reads an old exam and writes its model answers.
        public static let oldExam = "coach.old_exam"
    }
}

/// Why a coach action could not be done (the screens show nothing for it; the action is absent).
public enum CoachError: Error, CustomStringConvertible, Sendable {
    case missing(String)
    case nothingToAsk
    case notOpen

    public var description: String {
        switch self {
        case .missing(let what): "\(what) is gone."
        case .nothingToAsk: "There are no questions for this yet."
        case .notOpen: "That round or exam has ended."
        }
    }
}

/// How the coach words things (DESIGN 9 strings): durations, slides, days.
public enum CoachText {
    /// "5 h 15 min", "45 min", "2 h".
    public static func duration(minutes: Int) -> String {
        let minutes = max(0, minutes)
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    public static func duration(seconds: Double) -> String {
        duration(minutes: Int((max(0, seconds) / 60).rounded()))
    }

    /// "slides 13–21", "slide 12", "" without pages.
    public static func slides(_ first: Int?, _ last: Int?) -> String {
        guard let first else { return "" }
        guard let last, last > first else { return "slide \(first)" }
        return "slides \(first)–\(last)"
    }

    /// "Tue 9 Feb, 10:00" (the day alone when all-day).
    public static func dayTime(_ date: Date, allDay: Bool = false) -> String {
        ChangeSummary.dayTime(date, allDay: allDay, timeZone: CoachModule.timeZone)
    }

    /// "Tue 9 Feb".
    public static func day(_ day: CalendarDay) -> String {
        ChangeSummary.day(day.start(in: CoachModule.timeZone).addingTimeInterval(12 * 3_600), timeZone: CoachModule.timeZone)
    }

    /// "14 Dec – 8 Jan", "22 Feb – 7 Mar".
    public static func range(_ first: CalendarDay, _ last: CalendarDay) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let firstMonth = months[(first.month - 1 + 12) % 12]
        let lastMonth = months[(last.month - 1 + 12) % 12]
        if first.month == last.month, first.year == last.year { return "\(first.day)–\(last.day) \(lastMonth)" }
        return "\(first.day) \(firstMonth) – \(last.day) \(lastMonth)"
    }

    /// "Mon", "Fri–Mon" style weekday lists ("Fri, Sat, Sun, Mon" → "Fri–Mon" when consecutive).
    public static func weekdays(_ days: [Int]) -> String {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let valid = days.filter { (1...7).contains($0) }
        guard let first = valid.first else { return "" }
        // Consecutive across the week's end (Fri, Sat, Sun, Mon).
        let consecutive = valid.count > 2 && zip(valid, valid.dropFirst()).allSatisfy { ($0 % 7) + 1 == $1 }
        if consecutive, let last = valid.last { return "\(names[first - 1])–\(names[last - 1])" }
        return valid.map { names[$0 - 1] }.joined(separator: ", ")
    }

    /// At most `count` characters, "…" when cut; whitespace runs as one space.
    static func clip(_ text: String, _ count: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > count else { return flat }
        return String(flat.prefix(max(0, count - 1))) + "…"
    }

    /// At most `count` words.
    static func words(_ text: String, _ count: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > count else { return words.joined(separator: " ") }
        return words.prefix(count).joined(separator: " ")
    }

    /// "37:10" / "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Text for prompts: `&`, `<`, `>` and `"` escaped (data blocks and attributes alike).
enum CoachXML {
    static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            default: output.append(character)
            }
        }
        return output
    }
}
