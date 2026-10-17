import Foundation
import StudyCore

/// The days and times a German or English text mentions, found by a deterministic parser
/// relative to the date the text was written or said (in the university's time zone).
///
/// Recognized: "29 October", "29. Oktober 2026", "29th of Oct", "the 23rd of October", "October 29",
/// "October the 23rd", "Oct 29th, 2026", "21.10.", "21.10.2026", "2026-10-29", weekdays
/// ("Thursday", "Donnerstag", "next Friday", "nächsten Freitag": the next such day; on the same
/// weekday also a week later), "Tuesday next week" / "nächste Woche Dienstag" (that weekday of the
/// next calendar week), heute/today, morgen/tomorrow, übermorgen; times "23:59", "23.59 Uhr",
/// "16 Uhr", "16h", "4 pm", "4 PM", "4:00 PM", "4:30 p.m.", "noon"/"Mittag",
/// "midnight"/"Mitternacht". A weekday right before a date adds no day of its own. "next week" /
/// "nächste Woche" alone is a week (`weeks`), never a day.
///
/// Extractors accept a model's date for the calendar only when this parser finds that day in the
/// quote (and that time, when the quote has one). Moved from MailIntelligence in M3 (which keeps
/// a typealias); spoken forms added for lecture transcripts and the composer.
public struct DateMentions: Hashable, Sendable {
    /// Every day mentioned (a lone weekday may stand for two candidate days).
    public var days: Set<CalendarDay>
    /// Every time of day mentioned, in minutes after midnight (midnight counts as 23:59 and 24:00).
    public var minutes: Set<Int>
    /// Mondays of weeks mentioned without a day ("next week", "diese Woche"). Never confirms a
    /// due day; a session proposal may use it to find the one session of that week.
    public var weeks: Set<CalendarDay>

    public init(days: Set<CalendarDay> = [], minutes: Set<Int> = [], weeks: Set<CalendarDay> = []) {
        self.days = days
        self.minutes = minutes
        self.weeks = weeks
    }

    public var isEmpty: Bool { days.isEmpty && minutes.isEmpty && weeks.isEmpty }

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
    public func verdict(for due: Date, allDay: Bool, timeZone: TimeZone = DeadlinesModule.timeZone) -> Verdict {
        let day = CalendarDay(due, in: timeZone)
        guard days.contains(day) else { return .unconfirmed }
        guard !minutes.isEmpty else { return .confirmed(withTime: false) }
        guard !allDay else { return .unconfirmed }
        let minute = DateMentions.minute(of: due, timeZone: timeZone)
        return minutes.contains { abs($0 - minute) <= 1 } ? .confirmed(withTime: true) : .unconfirmed
    }

    /// Minutes after local midnight of `date`.
    public static func minute(of date: Date, timeZone: TimeZone = DeadlinesModule.timeZone) -> Int {
        let parts = Calendar.gregorian(in: timeZone).dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    // MARK: - Parsing

    /// One mention and the stretch of the original text it was read from.
    public struct Mention: Hashable, Sendable {
        public enum Value: Hashable, Sendable {
            /// Candidate days, earliest first ("next Friday" on a Friday is two).
            case days([CalendarDay])
            /// Minutes after midnight (midnight is 23:59 and 24:00).
            case minutes([Int])
            /// The Monday of a week named without a day.
            case week(CalendarDay)
        }

        public var value: Value
        /// In the text that was parsed, including words that belong to it ("next", "Uhr", "PM").
        public var range: Range<String.Index>
    }

    /// The mentions in `text`, written or said at `reference`.
    public static func parse(_ text: String, reference: Date, timeZone: TimeZone = DeadlinesModule.timeZone) -> DateMentions {
        var parser = Parser(tokens: Lexer.tokens(of: text), reference: CalendarDay(reference, in: timeZone))
        parser.run()
        return DateMentions(days: parser.days, minutes: parser.minutes, weeks: parser.weeks)
    }

    /// Every mention in `text` in text order, with its range in `text`.
    public static func mentions(in text: String, reference: Date, timeZone: TimeZone = DeadlinesModule.timeZone) -> [Mention] {
        let tokens = Lexer.tokens(of: text)
        var parser = Parser(tokens: tokens, reference: CalendarDay(reference, in: timeZone))
        parser.run()
        return parser.found
            .sorted { $0.tokens.lowerBound < $1.tokens.lowerBound }
            .map { Mention(value: $0.value, range: tokens[$0.tokens.lowerBound].start..<tokens[$0.tokens.upperBound - 1].end) }
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
        /// Every letter upper-case ("PM", "AM").
        var uppercase = false
        /// The token's stretch of the original text.
        var start: String.Index
        var end: String.Index

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
            var start = text.startIndex
            var end = text.startIndex
            func flush() {
                if !letters.isEmpty {
                    let capitalized = letters.first?.isUppercase ?? false
                    let uppercase = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
                    tokens.append(Token(
                        kind: .word(TextFolding.fold(letters), capitalized: capitalized), spaced: spaced, uppercase: uppercase,
                        start: start, end: end
                    ))
                    letters = ""
                    spaced = false
                }
                if !digits.isEmpty {
                    let value = digits.count > 6 ? Int.max : (Int(digits) ?? Int.max)
                    tokens.append(Token(kind: .number(value, digits: digits.count), spaced: spaced, start: start, end: end))
                    digits = ""
                    spaced = false
                }
            }
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(after: index)
                for raw in NormalizedText.plain(text[index]) {
                    if raw.isWhitespace {
                        flush()
                        spaced = true
                    } else if raw.isNumber, raw.isASCII {
                        if !letters.isEmpty { flush() }
                        if digits.isEmpty { start = index }
                        digits.append(raw)
                        end = next
                    } else if raw.isLetter {
                        if !digits.isEmpty { flush() }
                        if letters.isEmpty { start = index }
                        letters.append(raw)
                        end = next
                    } else {
                        flush()
                        tokens.append(Token(kind: .punct(raw), spaced: spaced, start: index, end: next))
                        spaced = false
                    }
                }
                index = next
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
        var weeks: Set<CalendarDay> = []
        /// Token indices a mention consumed (a weekday among a date's adds nothing).
        var consumed = IndexSet()
        /// Mentions with their token ranges.
        var found: [(tokens: Range<Int>, value: Mention.Value)] = []
        /// The day the last explicit date added (nil when it was no valid day).
        private var added: CalendarDay?

        init(tokens: [Token], reference: CalendarDay) {
            self.tokens = tokens
            self.reference = reference
        }

        mutating func run() {
            var index = 0
            while index < tokens.count {
                added = nil
                if let end = explicitDate(at: index) {
                    consumed.insert(integersIn: index..<end)
                    if let added { found.append((index..<end, .days([added]))) }
                    index = end
                } else {
                    index += 1
                }
            }
            for index in tokens.indices where !consumed.contains(index) {
                weekdayOrRelative(at: index)
            }
            for index in tokens.indices where !consumed.contains(index) {
                week(at: index)
            }
            for index in tokens.indices where !consumed.contains(index) {
                time(at: index)
            }
        }

        func token(_ index: Int) -> Token? { tokens.indices.contains(index) ? tokens[index] : nil }

        func word(_ index: Int) -> String? { token(index)?.word }

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

        /// 29 October / 29. Oktober 2026 / 29th of Oct. / 23rd of October
        mutating func dayMonthName(at index: Int, day: Int) -> Int? {
            var cursor = index + 1
            if token(cursor)?.isPunct(".") == true { cursor += 1 }
            if let word = word(cursor), Self.ordinalSuffixes.contains(word), token(cursor)?.spaced == false {
                cursor += 1
            }
            if word(cursor) == "of" { cursor += 1 }
            guard let monthToken = token(cursor), let word = monthToken.word,
                  let month = Self.month(word, capitalized: true)
            else { return nil }
            cursor += 1
            if token(cursor)?.isPunct(".") == true, token(cursor)?.spaced == false { cursor += 1 }
            return year(after: cursor, month: month, day: day)
        }

        /// October 29 / Oct 29th, 2026 / October the 23rd
        mutating func monthNameDay(at index: Int, month: Int) -> Int? {
            var cursor = index + 1
            if token(cursor)?.isPunct(".") == true, token(cursor)?.spaced == false { cursor += 1 }
            // Spoken: "October the 23rd".
            if word(cursor) == "the", token(cursor + 1)?.number != nil { cursor += 1 }
            guard let dayToken = token(cursor), let day = dayToken.number, dayToken.digits <= 2, (1...31).contains(day) else {
                return nil
            }
            // "October 12:00" is not a day.
            if token(cursor + 1)?.isPunct(":") == true { return nil }
            cursor += 1
            if let word = word(cursor), Self.ordinalSuffixes.contains(word), token(cursor)?.spaced == false {
                cursor += 1
            }
            return year(after: cursor, month: month, day: day)
        }

        /// Reads an optional year at `cursor` (", 2026" or "2026"), adds the day, returns the end.
        mutating func year(after cursor: Int, month: Int, day: Int) -> Int {
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
            if value.month == month, value.day == day {
                days.insert(value)
                added = value
            }
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
            if candidate.month == month, candidate.day == day {
                days.insert(candidate)
                added = candidate
            }
        }

        // MARK: Weekdays and relative days

        mutating func record(_ range: ClosedRange<Int>, days values: [CalendarDay]) {
            for value in values { days.insert(value) }
            consumed.insert(integersIn: range.lowerBound...range.upperBound)
            found.append((range.lowerBound..<(range.upperBound + 1), .days(values.sorted())))
        }

        /// The Monday of the reference's week.
        var thisMonday: CalendarDay { reference.adding(days: 1 - reference.weekday) }

        mutating func weekdayOrRelative(at index: Int) {
            guard let current = token(index), let word = current.word else { return }
            switch word {
            case "today", "heute", "tonight":
                record(index...index, days: [reference])
                return
            case "tomorrow":
                let afterDay = self.word(index - 1) == "after" && self.word(index - 2) == "day"
                let start = afterDay ? (self.word(index - 3) == "the" ? index - 3 : index - 2) : index
                record(start...index, days: [reference.adding(days: afterDay ? 2 : 1)])
                return
            case "morgen":
                // "heute Morgen", "am Morgen", "guten Morgen" are mornings, not tomorrow.
                if let previous = self.word(index - 1),
                   ["heute", "gestern", "guten", "am", "jeden", "dem", "den", "einen", "vom", "morgen"].contains(previous) {
                    return
                }
                record(index...index, days: [reference.adding(days: 1)])
                return
            case "ubermorgen", "uebermorgen":
                record(index...index, days: [reference.adding(days: 2)])
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
            let previous = self.word(index - 1) ?? ""
            if Self.lastWords.contains(previous) { return }
            // "Tuesday next week", "Dienstag nächste Woche": that weekday of the next calendar week.
            if let after = self.word(index + 1), Self.nextWords.contains(after),
               let unit = self.word(index + 2), Self.weekWords.contains(unit) {
                record(index...(index + 2), days: [thisMonday.adding(days: 7 + weekday - 1)])
                return
            }
            // "next week Tuesday", "nächste Woche (am) Dienstag".
            let gap = ["on", "am"].contains(previous) ? 1 : 0
            if let unit = self.word(index - 1 - gap), Self.weekWords.contains(unit),
               let before = self.word(index - 2 - gap), Self.nextWords.contains(before) {
                record((index - 2 - gap)...index, days: [thisMonday.adding(days: 7 + weekday - 1)])
                return
            }
            let ahead = (weekday - reference.weekday + 7) % 7
            if Self.nextWords.contains(previous) {
                let first = reference.adding(days: ahead == 0 ? 7 : ahead)
                record((index - 1)...index, days: [first, first.adding(days: 7)])
            } else {
                let start = Self.thisWords.contains(previous) ? index - 1 : index
                if ahead == 0 {
                    record(start...index, days: [reference, reference.adding(days: 7)])
                } else {
                    record(start...index, days: [reference.adding(days: ahead)])
                }
            }
        }

        /// "next week", "nächste Woche", "this week", "diese Woche": a week, not a day.
        mutating func week(at index: Int) {
            guard let word = word(index), let unit = self.word(index + 1), Self.weekWords.contains(unit),
                  !consumed.contains(index + 1)
            else { return }
            let monday: CalendarDay
            if Self.nextWords.contains(word) {
                monday = thisMonday.adding(days: 7)
            } else if Self.thisWords.contains(word) {
                monday = thisMonday
            } else {
                return
            }
            weeks.insert(monday)
            consumed.insert(integersIn: index...(index + 1))
            found.append((index..<(index + 2), .week(monday)))
        }

        // MARK: Times

        mutating func time(at index: Int) {
            guard let current = token(index) else { return }
            if let word = current.word {
                switch word {
                case "noon", "midday", "mittag", "mittags":
                    addTime([12 * 60], index..<(index + 1))
                case "midnight", "mitternacht":
                    addTime([23 * 60 + 59, 24 * 60], index..<(index + 1))
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
                    guard let marker = word(cursor), ["uhr", "h"].contains(marker) else { return }
                }
                explicit = true
            }
            if let (meridiem, length) = meridiem(at: cursor) {
                guard (1...12).contains(hour) else { return }
                let hour24 = meridiem == .pm ? (hour % 12) + 12 : hour % 12
                addTime([hour24 * 60 + minute], index..<(cursor + length))
                return
            }
            if explicit {
                guard hour < 24 || minute == 0 else { return }
                let end = word(cursor).map { ["uhr", "h"].contains($0) } == true ? cursor + 1 : cursor
                addTime([hour * 60 + minute], index..<end)
                return
            }
            // "16 Uhr", "16h"
            if let marker = token(cursor), let word = marker.word {
                if word == "uhr" || (word == "h" && !marker.spaced) {
                    addTime([hour * 60], index..<(cursor + 1))
                }
            }
        }

        mutating func addTime(_ values: [Int], _ range: Range<Int>) {
            for value in values { minutes.insert(value) }
            consumed.insert(integersIn: range)
            found.append((range, .minutes(values)))
        }

        enum Meridiem { case am, pm }

        /// The meridiem at `index` and how many tokens it takes.
        func meridiem(at index: Int) -> (Meridiem, Int)? {
            guard let current = token(index), let word = current.word else { return nil }
            func dotted() -> Int {
                // "p.m." with its closing dot.
                token(index + 3)?.isPunct(".") == true && token(index + 3)?.spaced == false ? 4 : 3
            }
            switch word {
            case "am" where !current.isCapitalized || !current.spaced || current.uppercase:
                // German "am" (on the) follows numbers too ("bis 16 am Freitag"): only "4am", "4 am"
                // or "4 AM" followed by nothing date-like.
                if let next = self.word(index + 1), Self.weekday(next, capitalized: true) != nil { return nil }
                return (.am, 1)
            case "pm": return (.pm, 1)
            case "a" where token(index + 1)?.isPunct(".") == true && self.word(index + 2) == "m": return (.am, dotted())
            case "p" where token(index + 1)?.isPunct(".") == true && self.word(index + 2) == "m": return (.pm, dotted())
            default: return nil
            }
        }

        // MARK: Vocabulary

        static let ordinalSuffixes: Set<String> = ["st", "nd", "rd", "th"]
        static let nextWords: Set<String> = [
            "next", "nachsten", "nachste", "nachster", "naechsten", "naechste", "naechster", "kommenden", "kommende", "folgenden",
        ]
        static let thisWords: Set<String> = ["this", "diesen", "diese", "dieser", "coming"]
        static let lastWords: Set<String> = ["last", "letzten", "letzte", "vergangenen", "previous", "past"]
        static let weekWords: Set<String> = ["week", "woche"]

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

extension Calendar {
    /// Gregorian in `timeZone`, POSIX locale.
    static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}
