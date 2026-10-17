import Foundation
import StudyCore

/// The days and times a German or English text mentions, found by a deterministic parser
/// relative to the date the text was written (in the university's time zone).
///
/// Recognized: "29 October", "29. Oktober 2026", "29th of Oct", "October 29", "Oct 29th, 2026",
/// "21.10.", "21.10.2026", "2026-10-29", weekdays ("Thursday", "Donnerstag", "next Friday",
/// "nächsten Freitag": the next such day; on the same weekday also a week later), heute/today,
/// morgen/tomorrow, übermorgen; times "23:59", "23.59 Uhr", "16 Uhr", "16h", "4 pm", "4:30 p.m.",
/// "noon"/"Mittag", "midnight"/"Mitternacht". A weekday right before a date adds no day of its own.
///
/// The extractor accepts a model's date for the calendar only when this parser finds that day in
/// the quote (and that time, when the quote has one).
public struct DateMentions: Hashable, Sendable {
    /// Every day mentioned (a lone weekday may stand for two candidate days).
    public var days: Set<CalendarDay>
    /// Every time of day mentioned, in minutes after midnight (midnight counts as 23:59 and 24:00).
    public var minutes: Set<Int>

    public init(days: Set<CalendarDay> = [], minutes: Set<Int> = []) {
        self.days = days
        self.minutes = minutes
    }

    public var isEmpty: Bool { days.isEmpty && minutes.isEmpty }

    /// How a due date stands against the mentions.
    public enum Verdict: Hashable, Sendable {
        /// The day (and the time, when the text has one) is mentioned.
        case confirmed(withTime: Bool)
        /// The text does not support the date.
        case unconfirmed
    }

    /// Whether `due` (an all-day item when `allDay`) is what the text says. When the text names a
    /// time, the due time must be one of them (within a minute); an all-day item is then not
    /// confirmed.
    public func verdict(for due: Date, allDay: Bool, timeZone: TimeZone = MailIntelligenceModule.timeZone) -> Verdict {
        let day = CalendarDay(due, in: timeZone)
        guard days.contains(day) else { return .unconfirmed }
        guard !minutes.isEmpty else { return .confirmed(withTime: false) }
        guard !allDay else { return .unconfirmed }
        let parts = Calendar.gregorian(in: timeZone).dateComponents([.hour, .minute], from: due)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minutes.contains { abs($0 - minute) <= 1 } ? .confirmed(withTime: true) : .unconfirmed
    }

    // MARK: - Parsing

    /// The mentions in `text`, written at `reference`.
    public static func parse(_ text: String, reference: Date, timeZone: TimeZone = MailIntelligenceModule.timeZone) -> DateMentions {
        var parser = Parser(tokens: Lexer.tokens(of: text), reference: CalendarDay(reference, in: timeZone))
        return parser.run()
    }

    // MARK: Tokens

    struct Token: Hashable {
        enum Kind: Hashable {
            case number(Int, digits: Int)
            /// Folded word, and whether the original started with a capital letter.
            case word(String, capitalized: Bool)
            case punct(Character)
        }

        var kind: Kind
        /// Whitespace before this token.
        var spaced: Bool

        var number: Int? { if case .number(let value, _) = kind { return value }; return nil }
        var digits: Int { if case .number(_, let digits) = kind { return digits }; return 0 }
        var word: String? { if case .word(let value, _) = kind { return value }; return nil }
        var isCapitalized: Bool { if case .word(_, let capitalized) = kind { return capitalized }; return false }
        func isPunct(_ character: Character) -> Bool { kind == .punct(character) }
    }

    enum Lexer {
        static func tokens(of text: String) -> [Token] {
            var tokens: [Token] = []
            var spaced = false
            var letters = ""
            var digits = ""
            func flush() {
                if !letters.isEmpty {
                    let capitalized = letters.first?.isUppercase ?? false
                    tokens.append(Token(kind: .word(Folding.fold(letters), capitalized: capitalized), spaced: spaced))
                    letters = ""
                    spaced = false
                }
                if !digits.isEmpty {
                    let value = digits.count > 6 ? Int.max : (Int(digits) ?? Int.max)
                    tokens.append(Token(kind: .number(value, digits: digits.count), spaced: spaced))
                    digits = ""
                    spaced = false
                }
            }
            for raw in NormalizedText.plainCharacters(text) {
                if raw.isWhitespace {
                    flush()
                    spaced = true
                } else if raw.isNumber, raw.isASCII {
                    if !letters.isEmpty { flush() }
                    digits.append(raw)
                } else if raw.isLetter {
                    if !digits.isEmpty { flush() }
                    letters.append(raw)
                } else {
                    flush()
                    tokens.append(Token(kind: .punct(raw), spaced: spaced))
                    spaced = false
                }
            }
            flush()
            return tokens
        }
    }

    // MARK: Parser

    struct Parser {
        let tokens: [Token]
        let reference: CalendarDay
        var days: Set<CalendarDay> = []
        var minutes: Set<Int> = []
        /// Token indices a date consumed (a weekday among them adds nothing).
        var consumed = IndexSet()

        init(tokens: [Token], reference: CalendarDay) {
            self.tokens = tokens
            self.reference = reference
        }

        mutating func run() -> DateMentions {
            var index = 0
            while index < tokens.count {
                if let end = explicitDate(at: index) {
                    consumed.insert(integersIn: index..<end)
                    index = end
                } else {
                    index += 1
                }
            }
            for index in tokens.indices where !consumed.contains(index) {
                weekdayOrRelative(at: index)
                time(at: index)
            }
            return DateMentions(days: days, minutes: minutes)
        }

        func token(_ index: Int) -> Token? { tokens.indices.contains(index) ? tokens[index] : nil }

        // MARK: Explicit dates

        /// Parses an explicit date starting at `index`; returns the index after it.
        mutating func explicitDate(at index: Int) -> Int? {
            guard let first = token(index) else { return nil }
            // Digits glued to a word or a file name ("v1.pdf", "Sheet_01") are no date.
            if first.number != nil, !first.spaced, let previous = token(index - 1),
               previous.word != nil || previous.isPunct("_") || previous.isPunct(".") || previous.isPunct("/") || previous.isPunct("-") {
                return nil
            }
            if let year = first.number, first.digits == 4 { return isoDate(at: index, year: year) }
            if let day = first.number, first.digits <= 2, (1...31).contains(day) {
                return numericDate(at: index, day: day) ?? dayMonthName(at: index, day: day)
            }
            if let word = first.word, let month = Self.month(word, capitalized: first.isCapitalized) {
                return monthNameDay(at: index, month: month)
            }
            return nil
        }

        /// 2026-10-29
        mutating func isoDate(at index: Int, year: Int) -> Int? {
            guard let dash1 = token(index + 1), dash1.isPunct("-"), !dash1.spaced,
                  let monthToken = token(index + 2), let month = monthToken.number, !monthToken.spaced, (1...12).contains(month),
                  let dash2 = token(index + 3), dash2.isPunct("-"), !dash2.spaced,
                  let dayToken = token(index + 4), let day = dayToken.number, !dayToken.spaced, (1...31).contains(day),
                  dayToken.digits <= 2
            else { return nil }
            add(year: year, month: month, day: day)
            return index + 5
        }

        /// 21.10. / 21.10.2026 / 21.10.26
        mutating func numericDate(at index: Int, day: Int) -> Int? {
            guard let dot1 = token(index + 1), dot1.isPunct("."), !dot1.spaced,
                  let monthToken = token(index + 2), let month = monthToken.number, monthToken.digits <= 2, (1...12).contains(month),
                  let dot2 = token(index + 3), dot2.isPunct("."), !dot2.spaced
            else { return nil }
            if let yearToken = token(index + 4), let year = yearToken.number, !yearToken.spaced,
               yearToken.digits == 4 || yearToken.digits == 2 {
                add(year: yearToken.digits == 2 ? 2000 + year : year, month: month, day: day)
                return index + 5
            }
            addInferringYear(month: month, day: day)
            return index + 4
        }

        /// 29 October / 29. Oktober 2026 / 29th of Oct.
        mutating func dayMonthName(at index: Int, day: Int) -> Int? {
            var cursor = index + 1
            if token(cursor)?.isPunct(".") == true { cursor += 1 }
            if let word = token(cursor)?.word, ["st", "nd", "rd", "th"].contains(word), token(cursor)?.spaced == false {
                cursor += 1
            }
            if token(cursor)?.word == "of" { cursor += 1 }
            guard let monthToken = token(cursor), let word = monthToken.word,
                  let month = Self.month(word, capitalized: true)
            else { return nil }
            cursor += 1
            if token(cursor)?.isPunct(".") == true, token(cursor)?.spaced == false { cursor += 1 }
            if token(cursor)?.isPunct(",") == true, let year = token(cursor + 1)?.number, token(cursor + 1)?.digits == 4 {
                add(year: year, month: month, day: day)
                return cursor + 2
            }
            if let year = token(cursor)?.number, token(cursor)?.digits == 4 {
                add(year: year, month: month, day: day)
                return cursor + 1
            }
            addInferringYear(month: month, day: day)
            return cursor
        }

        /// October 29 / Oct 29th, 2026
        mutating func monthNameDay(at index: Int, month: Int) -> Int? {
            var cursor = index + 1
            if token(cursor)?.isPunct(".") == true, token(cursor)?.spaced == false { cursor += 1 }
            guard let dayToken = token(cursor), let day = dayToken.number, dayToken.digits <= 2, (1...31).contains(day) else {
                return nil
            }
            // "October 12:00" is not a day.
            if token(cursor + 1)?.isPunct(":") == true { return nil }
            cursor += 1
            if let word = token(cursor)?.word, ["st", "nd", "rd", "th"].contains(word), token(cursor)?.spaced == false {
                cursor += 1
            }
            if token(cursor)?.isPunct(",") == true, let year = token(cursor + 1)?.number, token(cursor + 1)?.digits == 4 {
                add(year: year, month: month, day: day)
                return cursor + 2
            }
            if let year = token(cursor)?.number, token(cursor)?.digits == 4 {
                add(year: year, month: month, day: day)
                return cursor + 1
            }
            addInferringYear(month: month, day: day)
            return cursor
        }

        mutating func add(year: Int, month: Int, day: Int) {
            let value = CalendarDay(year: year, month: month, day: day)
            if value.month == month, value.day == day { days.insert(value) }
        }

        /// The year that puts the day nearest the reference: up to three months back, else ahead.
        mutating func addInferringYear(month: Int, day: Int) {
            var candidate = CalendarDay(year: reference.year, month: month, day: day)
            guard candidate.month == month, candidate.day == day else { return }
            if reference.days(to: candidate) < -90 {
                candidate = CalendarDay(year: reference.year + 1, month: month, day: day)
            } else if reference.days(to: candidate) > 270 {
                candidate = CalendarDay(year: reference.year - 1, month: month, day: day)
            }
            if candidate.month == month, candidate.day == day { days.insert(candidate) }
        }

        // MARK: Weekdays and relative days

        mutating func weekdayOrRelative(at index: Int) {
            guard let current = token(index), let word = current.word else { return }
            switch word {
            case "today", "heute", "tonight":
                days.insert(reference)
                return
            case "tomorrow":
                let afterDay = token(index - 1)?.word == "after" && token(index - 2)?.word == "day"
                days.insert(reference.adding(days: afterDay ? 2 : 1))
                return
            case "morgen":
                // "heute Morgen", "am Morgen", "guten Morgen" are mornings, not tomorrow.
                if let previous = token(index - 1)?.word,
                   ["heute", "gestern", "guten", "am", "jeden", "dem", "den", "einen", "vom", "morgen"].contains(previous) {
                    return
                }
                days.insert(reference.adding(days: 1))
                return
            case "ubermorgen", "uebermorgen":
                days.insert(reference.adding(days: 2))
                return
            default:
                break
            }
            guard let weekday = Self.weekday(word, capitalized: current.isCapitalized) else { return }
            // A weekday right before a date ("Thursday, 29 October") is part of it.
            for offset in 1...4 {
                if consumed.contains(index + offset) { return }
                guard let next = token(index + offset) else { break }
                if next.number != nil || next.word.map({ !["the", "den", "dem", "der"].contains($0) }) == true { break }
            }
            let previous = token(index - 1)?.word ?? ""
            if ["last", "letzten", "letzte", "vergangenen", "previous", "past"].contains(previous) { return }
            let nextWeek = ["next", "nachsten", "nachste", "naechsten", "kommenden", "kommende", "folgenden"].contains(previous)
            let ahead = (weekday - reference.weekday + 7) % 7
            if nextWeek {
                let first = reference.adding(days: ahead == 0 ? 7 : ahead)
                days.insert(first)
                days.insert(first.adding(days: 7))
            } else if ahead == 0 {
                days.insert(reference)
                days.insert(reference.adding(days: 7))
            } else {
                days.insert(reference.adding(days: ahead))
            }
        }

        // MARK: Times

        mutating func time(at index: Int) {
            guard let current = token(index) else { return }
            if let word = current.word {
                switch word {
                case "noon", "midday", "mittag", "mittags": minutes.insert(12 * 60)
                case "midnight", "mitternacht":
                    minutes.insert(23 * 60 + 59)
                    minutes.insert(24 * 60)
                default: break
                }
                return
            }
            guard let hour = current.number, current.digits <= 2, hour <= 24 else { return }
            // Not the minutes of a time already read ("23:59" is read at "23").
            if let previous = token(index - 1), previous.isPunct(":") || previous.isPunct("."), !current.spaced,
               token(index - 2)?.number != nil {
                return
            }
            var cursor = index + 1
            var minute = 0
            var explicit = false
            if let separator = token(cursor), separator.isPunct(":") || separator.isPunct("."), !separator.spaced,
               let minuteToken = token(cursor + 1), let value = minuteToken.number, minuteToken.digits == 2, !minuteToken.spaced,
               value < 60 {
                let colon = separator.isPunct(":")
                cursor += 2
                minute = value
                // "21.10." is a date, "23.59 Uhr" a time: a dot needs "Uhr"/"h" after it.
                if !colon {
                    guard let marker = token(cursor)?.word, ["uhr", "h"].contains(marker) else { return }
                }
                explicit = true
            }
            if let meridiem = meridiem(at: cursor) {
                guard (1...12).contains(hour) else { return }
                let hour24 = meridiem == .pm ? (hour % 12) + 12 : hour % 12
                minutes.insert(hour24 * 60 + minute)
                return
            }
            if explicit {
                guard hour < 24 || minute == 0 else { return }
                minutes.insert(hour * 60 + minute)
                return
            }
            // "16 Uhr", "16h"
            if let marker = token(cursor), let word = marker.word {
                if word == "uhr" || (word == "h" && !marker.spaced) {
                    minutes.insert(hour * 60)
                }
            }
        }

        enum Meridiem { case am, pm }

        func meridiem(at index: Int) -> Meridiem? {
            guard let word = token(index)?.word else { return nil }
            switch word {
            case "am" where token(index)?.isCapitalized == false || token(index)?.spaced == false:
                // German "am" (on the) follows numbers too ("bis 16 am Freitag"): only "4am"/"4 am" lower-case
                // followed by nothing date-like.
                if let next = token(index + 1)?.word, Self.weekday(next, capitalized: true) != nil { return nil }
                return .am
            case "pm": return .pm
            case "a" where token(index + 1)?.isPunct(".") == true && token(index + 2)?.word == "m": return .am
            case "p" where token(index + 1)?.isPunct(".") == true && token(index + 2)?.word == "m": return .pm
            default: return nil
            }
        }

        // MARK: Vocabulary

        static func month(_ word: String, capitalized: Bool) -> Int? {
            switch word {
            case "january", "januar", "janner", "jan": 1
            case "february", "februar", "feber", "feb": 2
            case "march", "marz", "maerz", "mar", "mrz": 3
            case "april", "apr": 4
            case "may" where capitalized: 5
            case "mai": 5
            case "june", "juni", "jun": 6
            case "july", "juli", "jul": 7
            case "august", "aug": 8
            case "september", "sept", "sep": 9
            case "october", "oktober", "oct", "okt": 10
            case "november", "nov": 11
            case "december", "dezember", "dec", "dez": 12
            default: nil
            }
        }

        /// ISO weekday (1 = Monday). Three-letter abbreviations only capitalized ("Sat", not "sat").
        static func weekday(_ word: String, capitalized: Bool) -> Int? {
            switch word {
            case "monday", "montag": 1
            case "tuesday", "dienstag": 2
            case "wednesday", "mittwoch": 3
            case "thursday", "donnerstag": 4
            case "friday", "freitag": 5
            case "saturday", "samstag", "sonnabend": 6
            case "sunday", "sonntag": 7
            case "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun":
                capitalized ? ["mon": 1, "tue": 2, "tues": 2, "wed": 3, "thu": 4, "thur": 4, "thurs": 4, "fri": 5, "sat": 6, "sun": 7][word] : nil
            default: nil
            }
        }
    }
}
