import Foundation
import StudyCore

/// Dates written on slides: "13-Oct-26", "13 October 2026", "13. Oktober 2026", "October 13, 2026",
/// "13.10.2026", "2026-10-13". Slash dates (US/EU ambiguous) are ignored.
enum SlideDate {
    static let months: [String: Int] = [
        "jan": 1, "january": 1, "januar": 1, "jänner": 1,
        "feb": 2, "february": 2, "februar": 2,
        "mar": 3, "march": 3, "mär": 3, "märz": 3, "mrz": 3, "maerz": 3,
        "apr": 4, "april": 4,
        "may": 5, "mai": 5,
        "jun": 6, "june": 6, "juni": 6,
        "jul": 7, "july": 7, "juli": 7,
        "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "okt": 10, "oktober": 10,
        "nov": 11, "november": 11,
        "dec": 12, "december": 12, "dez": 12, "dezember": 12,
    ]

    static func isMonthName(_ word: String) -> Bool {
        months[word.lowercased().trimmingCharacters(in: .punctuationCharacters)] != nil
    }

    /// The first date found in `text`.
    static func day(in text: String) -> CalendarDay? {
        let numeric = /\b(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})\b/
        let iso = /\b(\d{4})-(\d{2})-(\d{2})\b/
        let dayMonthYear = /\b(\d{1,2})\.?[\s\-\/]*([A-Za-zÄäÖöÜüé]{3,9})\.?[\s\-\/,]*(\d{4}|\d{2})\b/
        let monthDayYear = /([A-Za-zÄäÖöÜüé]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b/

        var found: [(Range<String.Index>, CalendarDay)] = []
        for match in text.matches(of: iso) {
            if let day = make(year: match.1, month: Int(match.2), day: Int(match.3)) { found.append((match.range, day)) }
        }
        for match in text.matches(of: numeric) {
            if let day = make(year: match.3, month: Int(match.2), day: Int(match.1)) { found.append((match.range, day)) }
        }
        for match in text.matches(of: dayMonthYear) {
            if let month = months[match.2.lowercased()], let day = make(year: match.3, month: month, day: Int(match.1)) {
                found.append((match.range, day))
            }
        }
        for match in text.matches(of: monthDayYear) {
            if let month = months[match.1.lowercased()], let day = make(year: match.3, month: month, day: Int(match.2)) {
                found.append((match.range, day))
            }
        }
        return found.min { $0.0.lowerBound < $1.0.lowerBound }?.1
    }

    private static func make(year: Substring, month: Int?, day: Int?) -> CalendarDay? {
        guard var year = Int(year), let month, let day else { return nil }
        // Two-digit years only from a plausible range: "1.2.3" is a version, not 2003.
        if year < 100 {
            guard (15...40).contains(year) else { return nil }
            year += 2000
        }
        guard (2000...2099).contains(year) else { return nil }
        return CalendarDay(rawValue: String(format: "%04d-%02d-%02d", year, month, day))
    }
}
