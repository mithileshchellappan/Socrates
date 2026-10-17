import Filing
import Foundation
import StudyCore
import StudyUI

/// The few words filing UI shows: "Lecture 3 · Wed 21 Oct", "58 slides", "44:34".
enum FilingText {
    /// "Lecture 3", "Exercise 2", the lecture's title, or "New Lecture".
    static func lecture(_ place: FilingPlace) -> String {
        if let number = place.number {
            let kind = place.sessionKind ?? .lecture
            switch kind {
            case .exercise: return String(localized: "Exercise \(number)")
            case .tutorial: return String(localized: "Tutorial \(number)")
            case .seminar: return String(localized: "Seminar \(number)")
            default: return String(localized: "Lecture \(number)")
            }
        }
        if !place.title.isEmpty { return place.title }
        switch place.sessionKind {
        case .exercise?: return String(localized: "Exercise")
        case .tutorial?: return String(localized: "Tutorial")
        case .seminar?: return String(localized: "Seminar")
        default: return String(localized: "New Lecture")
        }
    }

    /// "Lecture 3 · Wed 21 Oct", or just one of the two.
    static func line(_ place: FilingPlace, zone: TimeZone = .filing) -> String {
        [lecture(place), place.date.map { day($0, zone: zone) }].compactMap(\.self).joined(separator: " · ")
    }

    /// "Wed 21 Oct" in the user's language.
    static func day(_ date: Date, zone: TimeZone = .filing) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = zone
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    /// "10:15" for a session's start.
    static func time(_ date: Date, zone: TimeZone = .filing) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "58 slides" or "1:08:13".
    static func size(pageCount: Int?, duration: Double?) -> String? {
        if let duration, duration > 0 { return TimeText.clock(duration) }
        if let pageCount { return String(localized: "\(pageCount) slides") }
        return nil
    }
}

extension TimeZone {
    /// Lecture dates are shown in the university's time zone.
    static let filing = TimeZone(identifier: "Europe/Lisbon") ?? .current
}
