import Foundation
import StudyCore
import StudyUI

/// How the Mail screen writes dates: the list's "13:37" / "Yesterday" / "Tue 13 Oct", the
/// reader's "Today, 13:37", a found item's "Thu 29 Oct" + "23:59". Days use `DayText`, the one
/// day format of the app; times are shown in SF Mono by the views.
struct MailDateText: Sendable {
    var locale: Locale
    var timeZone: TimeZone

    init(locale: Locale = .current, timeZone: TimeZone = .current) {
        self.locale = locale
        self.timeZone = timeZone
    }

    /// A list row's time: the clock today, "Yesterday", else the day.
    enum ListLabel: Hashable, Sendable {
        case clock(String)
        case yesterday
        case day(String)

        var text: String {
            switch self {
            case .clock(let text), .day(let text): text
            case .yesterday: String(localized: "Yesterday")
            }
        }

        /// The clock is drawn in SF Mono.
        var isClock: Bool {
            if case .clock = self { return true }
            return false
        }
    }

    func listLabel(_ date: Date, now: Date) -> ListLabel {
        let day = CalendarDay(date, in: timeZone)
        let today = CalendarDay(now, in: timeZone)
        if day == today { return .clock(clock(date)) }
        if day == today.adding(days: -1) { return .yesterday }
        return .day(self.day(date))
    }

    /// The reader's date line: "Today, 13:37", "Yesterday, 16:10", "Tue 13 Oct, 16:10".
    func readerLabel(_ date: Date, now: Date) -> String {
        let day = CalendarDay(date, in: timeZone)
        let today = CalendarDay(now, in: timeZone)
        let time = clock(date)
        if day == today { return String(localized: "Today, \(time)") }
        if day == today.adding(days: -1) { return String(localized: "Yesterday, \(time)") }
        return "\(self.day(date)), \(time)"
    }

    /// "13:37" (the locale's hour cycle).
    func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute())
    }

    /// "Tue 13 Oct" (`DayText`).
    func day(_ date: Date) -> String {
        DayText.day(date, locale: locale, timeZone: timeZone)
    }

    /// A due date as its day and, unless it is all-day, its clock time.
    func due(_ date: Date, allDay: Bool) -> (day: String, time: String?) {
        (day(date), allDay ? nil : clock(date))
    }
}

/// Small text helpers for the Mail screen.
enum MailText {
    /// "SS" for "Sam Student", "LP" for "LMS Portal", "CD" for "Dr. Cy Demo" (titles skipped), the
    /// address's first letter otherwise.
    static func initials(_ name: String, address: String = "") -> String {
        let titles: Set<String> = ["dr", "dr.", "prof", "prof.", "mr", "mr.", "ms", "ms.", "mrs", "mrs.", "herr", "frau"]
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !titles.contains($0.lowercased()) && $0.first?.isLetter == true }
        if words.count >= 2, let first = words.first?.first, let last = words.last?.first {
            return String([first, last]).uppercased()
        }
        if let word = words.first {
            return String(word.prefix(2)).uppercased()
        }
        return address.first.map { String($0).uppercased() } ?? ""
    }

    /// "412 KB".
    static func byteCount(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory))
    }

    /// "Re: subject" without stacking prefixes ("Re:", "AW:", "Aw:", "Antw:", "Fwd:" stay once).
    static func replySubject(_ subject: String) -> String {
        var rest = Substring(subject)
        let prefixes = ["re:", "aw:", "antw:", "wg:"]
        var stripped = true
        while stripped {
            stripped = false
            let trimmed = rest.drop(while: \.isWhitespace)
            for prefix in prefixes where trimmed.lowercased().hasPrefix(prefix) {
                rest = trimmed.dropFirst(prefix.count)
                stripped = true
                break
            }
        }
        let base = rest.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Re:" : "Re: \(base)"
    }

    /// Recipients typed into a To field: "Name <a@b>", "a@b", separated by commas or semicolons.
    static func addresses(from text: String) -> [MailAddress] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).compactMap { part in
            let item = part.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return nil }
            if let open = item.lastIndex(of: "<"), let close = item.lastIndex(of: ">"), open < close {
                let address = item[item.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let name = item[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
                return isAddress(address) ? MailAddress(name: name, address: address) : nil
            }
            return isAddress(item) ? MailAddress(address: item) : nil
        }
    }

    /// Looks like `local@domain.tld` (no spaces, one "@", a dot in the domain).
    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}
