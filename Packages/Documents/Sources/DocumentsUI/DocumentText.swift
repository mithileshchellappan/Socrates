import Foundation
import StudyCore
import StudyUI
import SwiftUI

/// The Documents screen's words and formats (docs/plan-docs.md §6 "Strings"; DESIGN 9): the kinds,
/// the file type, "6 pages", the added day, "p. 12", a date row's day or range.
enum DocumentText {
    /// "Handbook", "Regulations", "CV", "Transcript", "Certificate", "Letter"; anything else
    /// (`other`, or not summarised yet) "Document".
    static func kind(_ kind: DocumentKind) -> String {
        switch kind {
        case .cv: String(localized: "CV")
        case .handbook: String(localized: "Handbook")
        case .regulations: String(localized: "Regulations")
        case .transcript: String(localized: "Transcript")
        case .certificate: String(localized: "Certificate")
        case .letter: String(localized: "Letter")
        default: String(localized: "Document")
        }
    }

    /// "PDF", "Word", "RTF", "Pages", "Markdown", "Text", "PNG": what the original is.
    static func fileType(_ document: StudyDocument) -> String {
        let ext = (document.fileName as NSString).pathExtension.lowercased()
        switch document.fileKind {
        case .pdf?: return "PDF"
        case .word?: return ext == "odt" ? "OpenDocument" : "Word"
        case .richText?: return "RTF"
        case .pages?: return "Pages"
        case .text?: return ["md", "markdown"].contains(ext) ? "Markdown" : String(localized: "Text")
        case .image?, nil: return ext.isEmpty ? String(localized: "Document") : ext.uppercased()
        }
    }

    /// The glyph of the original's kind (the file tile before its thumbnail, a file without one).
    static func fileGlyph(_ document: StudyDocument) -> String {
        switch document.fileKind {
        case .image?: "photo"
        case .text?: "doc.plaintext"
        default: "doc.richtext"
        }
    }

    /// "6 pages" / "1 page"; nil for an image (one picture is not a page) and before reading.
    static func pages(_ document: StudyDocument) -> String? {
        guard document.pageCount > 0, document.fileKind != .image else { return nil }
        return document.pageCount == 1 ? String(localized: "1 page") : String(localized: "\(document.pageCount) pages")
    }

    /// "2.4 MB" (DESIGN 9: binary units, as attachment sizes).
    static func size(_ document: StudyDocument) -> String {
        Int64(document.byteCount).formatted(.byteCount(style: .memory))
    }

    /// "p. 12" (the digits in SF Mono where it is drawn).
    static func page(_ page: Int) -> String {
        "p.\u{00A0}\(page)"
    }

    // MARK: Days

    /// The list's added day: "19 Oct" this year, "19 Oct 2025" another.
    static func listDay(_ date: Date, now: Date) -> String {
        let calendar = gregorian
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(style(sameYear ? "\(day: .defaultDigits) \(month: .abbreviated)" : "\(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)"))
    }

    /// The reader's "Added Mon 19 Oct" ("Added Sun 19 Oct 2025" from another year).
    static func added(_ date: Date, now: Date) -> String {
        let calendar = gregorian
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear ? DayText.day(date) : date.formatted(style("\(weekday: .abbreviated) \(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)"))
        return String(localized: "Added \(day)")
    }

    /// A date row's day: "Mon 1 Feb", a range "18–29 Jan" / "28 Dec–8 Jan", with ", 10:15" when the
    /// document states a time. The year is added when the day is not within the half year behind
    /// and the year ahead ("Tue 30 Sep 2025").
    static func day(_ date: DocumentDate, now: Date) -> String {
        let timeZone = TimeZone.current
        let start = date.day.start(in: timeZone)
        let today = CalendarDay(now, in: timeZone)
        func needsYear(_ day: CalendarDay) -> Bool {
            let offset = today.days(to: day)
            return offset < -183 || offset > 365
        }
        var label: String
        if let endDay = date.endDay, endDay != date.day {
            let end = endDay.start(in: timeZone)
            let years = needsYear(date.day) || needsYear(endDay)
            if endDay.year == date.day.year, endDay.month == date.day.month {
                let tail = years ? style("\(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)") : style("\(day: .defaultDigits) \(month: .abbreviated)")
                label = "\(date.day.day)–\(end.formatted(tail))"
            } else {
                let each = years ? style("\(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)") : style("\(day: .defaultDigits) \(month: .abbreviated)")
                label = "\(start.formatted(each))–\(end.formatted(each))"
            }
        } else if needsYear(date.day) {
            label = start.formatted(style("\(weekday: .abbreviated) \(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)"))
        } else {
            label = DayText.day(start)
        }
        if let time = date.time?.trimmingCharacters(in: .whitespaces), !time.isEmpty {
            label += ", \(time)"
        }
        return label
    }

    private static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private static func style(_ format: Date.FormatString) -> Date.VerbatimFormatStyle {
        Date.VerbatimFormatStyle(format: format, locale: .current, timeZone: .current, calendar: Calendar(identifier: .gregorian))
    }

    // MARK: Mono digits

    /// `string` as one `Text` whose digit runs are SF Mono ("6 pages", "19 Oct"): the plan's
    /// "digits in SF Mono" inside a line of text.
    static func monoDigits(_ string: String, size: CGFloat, weight: Font.Weight = .regular) -> Text {
        var result = Text(verbatim: "")
        var run = ""
        var runIsDigits = false
        func flush() {
            guard !run.isEmpty else { return }
            let piece = Text(verbatim: run)
            result = runIsDigits
                ? Text("\(result)\(piece.font(.mono(size, weight: weight)))")
                : Text("\(result)\(piece.font(.system(size: size, weight: weight)))")
            run = ""
        }
        for character in string {
            let isDigit = character.isASCII && character.isNumber
            if isDigit != runIsDigits { flush() }
            runIsDigits = isDigit
            run.append(character)
        }
        flush()
        return result
    }
}
