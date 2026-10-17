import Foundation
import StudyCore

/// Weekly slots from an iCalendar file (a campus system or LMS export): every weekly or fortnightly
/// VEVENT becomes one slot per weekday it repeats on. Pure parsing; saving is the caller's.
public enum ICSSlotImporter {
    /// Slots for `courseID` in `text`, without those `existing` already has (same kind, weekday
    /// and start). Floating times are read in `timeZone`; UTC times are converted to it.
    public static func slots(
        from text: String,
        courseID: Course.ID,
        existing: [WeeklySlot] = [],
        timeZone: TimeZone = TimeZone(identifier: "Europe/Lisbon") ?? .current
    ) -> [WeeklySlot] {
        var result: [WeeklySlot] = []
        func isKnown(_ slot: WeeklySlot) -> Bool {
            (existing + result).contains {
                $0.courseID == slot.courseID && $0.kind == slot.kind && $0.weekday == slot.weekday && $0.startMinute == slot.startMinute
            }
        }
        for event in events(in: text) {
            for slot in slots(for: event, courseID: courseID, timeZone: timeZone) where !isKnown(slot) {
                result.append(slot)
            }
        }
        return result
    }

    /// "Übung", "Exercise" → exercise; "Tutorium", "Tutorial" → tutorial; "Seminar" → seminar;
    /// anything else is a lecture.
    public static func kind(forSummary summary: String) -> SessionKind {
        let text = summary.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de"))
        if text.contains("ubung") || text.contains("uebung") || text.contains("exercise") { return .exercise }
        if text.contains("tutori") { return .tutorial }
        if text.contains("seminar") || text.contains("proseminar") { return .seminar }
        return .lecture
    }

    // MARK: - Events

    struct Property {
        var name: String
        var parameters: [String: String]
        var value: String
    }

    typealias Event = [String: Property]

    /// VEVENT blocks as their properties (the last of a name wins), lines unfolded.
    static func events(in text: String) -> [Event] {
        var events: [Event] = []
        var current: Event?
        var depth = 0
        for line in unfoldedLines(text) {
            guard let property = parse(line) else { continue }
            switch (property.name, property.value.uppercased()) {
            case ("BEGIN", "VEVENT"):
                current = [:]
                depth = 0
            case ("BEGIN", _):
                if current != nil { depth += 1 }
            case ("END", "VEVENT"):
                if let event = current { events.append(event) }
                current = nil
            case ("END", _):
                if current != nil { depth = max(0, depth - 1) }
            default:
                // Properties of nested components (VALARM) are not the event's.
                if depth == 0 { current?[property.name] = property }
            }
        }
        return events
    }

    static func unfoldedLines(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacing("\r\n", with: "\n").replacing("\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// `NAME;PARAM=VALUE;…:value` (quoted parameter values may hold ":" and ";").
    static func parse(_ line: String) -> Property? {
        var inQuotes = false
        var colon: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ":", !inQuotes {
                colon = index
                break
            }
        }
        guard let colon else { return nil }
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        var parts: [String] = []
        var part = ""
        inQuotes = false
        for character in head {
            if character == "\"" { inQuotes.toggle(); continue }
            if character == ";", !inQuotes {
                parts.append(part)
                part = ""
            } else {
                part.append(character)
            }
        }
        parts.append(part)
        guard let name = parts.first?.uppercased(), !name.isEmpty else { return nil }
        var parameters: [String: String] = [:]
        for parameter in parts.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parameters[pair[0].uppercased()] = pair[1] }
        }
        return Property(name: name, parameters: parameters, value: value)
    }

    // MARK: - Slots

    static func slots(for event: Event, courseID: Course.ID, timeZone fallback: TimeZone) -> [WeeklySlot] {
        guard let start = event["DTSTART"], let rule = event["RRULE"].map({ recurrence($0.value) }),
              rule["FREQ"]?.uppercased() == "WEEKLY"
        else { return [] }
        let interval = Int(rule["INTERVAL"] ?? "1") ?? 1
        guard interval == 1 || interval == 2 else { return [] }
        guard let begin = dateTime(start, fallback: fallback) else { return [] }
        let zone = begin.zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: begin.date)
        guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday,
              let year = parts.year, let month = parts.month, let day = parts.day else { return [] }

        var minutes = 90
        if let end = event["DTEND"].flatMap({ dateTime($0, fallback: zone) }) {
            minutes = Int((end.date.timeIntervalSince(begin.date) / 60).rounded())
        } else if let duration = event["DURATION"].flatMap({ durationMinutes($0.value) }) {
            minutes = duration
        }
        guard minutes > 0, minutes < 24 * 60 else { return [] }

        let until = rule["UNTIL"].flatMap { untilDay($0, zone: zone) }
        let summary = unescape(event["SUMMARY"]?.value ?? "")
        let room = unescape(event["LOCATION"]?.value ?? "")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let isoStart = isoWeekday(weekday)
        let weekdays = (rule["BYDAY"] ?? "")
            .split(separator: ",")
            .compactMap { code in weekdayCodes[String(code.suffix(2)).uppercased()] }
        return (weekdays.isEmpty ? [isoStart] : weekdays).map { isoWeekday in
            WeeklySlot(
                courseID: courseID,
                kind: kind(forSummary: summary),
                weekday: isoWeekday,
                startMinute: hour * 60 + minute,
                durationMinutes: minutes,
                room: room,
                timeZone: zone.identifier,
                validFrom: CalendarDay(year: year, month: month, day: day),
                validUntil: until,
                weekInterval: interval
            )
        }
    }

    static let weekdayCodes = ["MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6, "SU": 7]

    /// Calendar weekday (1 = Sunday) → ISO weekday (1 = Monday).
    static func isoWeekday(_ weekday: Int) -> Int {
        weekday == 1 ? 7 : weekday - 1
    }

    static func recurrence(_ value: String) -> [String: String] {
        var parts: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let items = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if items.count == 2 { parts[items[0].uppercased()] = items[1] }
        }
        return parts
    }

    /// A DATE-TIME in its TZID, UTC ("Z", shown in `fallback`) or floating (in `fallback`).
    /// All-day dates are not slots.
    static func dateTime(_ property: Property, fallback: TimeZone) -> (date: Date, zone: TimeZone)? {
        let value = property.value.trimmingCharacters(in: .whitespaces)
        guard property.parameters["VALUE"]?.uppercased() != "DATE", value.count >= 15 else { return nil }
        let isUTC = value.hasSuffix("Z")
        let zone = property.parameters["TZID"].flatMap(TimeZone.init(identifier:)) ?? fallback
        guard let date = parseDateTime(String(value.prefix(15)), zone: isUTC ? .gmt : zone) else { return nil }
        return (date, zone)
    }

    /// "20261014T101500" in `zone`.
    static func parseDateTime(_ value: String, zone: TimeZone) -> Date? {
        let digits = value.replacing("T", with: "")
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        func number(_ from: Int, _ length: Int) -> Int? {
            let start = digits.index(digits.startIndex, offsetBy: from)
            return Int(digits[start..<digits.index(start, offsetBy: length)])
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(
            year: number(0, 4), month: number(4, 2), day: number(6, 2),
            hour: number(8, 2), minute: number(10, 2), second: number(12, 2)
        ))
    }

    /// UNTIL as the last day in `zone` ("20270212" or "20270212T225959Z").
    static func untilDay(_ value: String, zone: TimeZone) -> CalendarDay? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 8, let year = Int(trimmed.prefix(4)), let month = Int(trimmed.dropFirst(4).prefix(2)),
           let day = Int(trimmed.suffix(2)) {
            return CalendarDay(year: year, month: month, day: day)
        }
        guard trimmed.count >= 15,
              let date = parseDateTime(String(trimmed.prefix(15)), zone: trimmed.hasSuffix("Z") ? .gmt : zone)
        else { return nil }
        return CalendarDay(date, in: zone)
    }

    /// "PT1H30M" → 90.
    static func durationMinutes(_ value: String) -> Int? {
        guard let match = value.uppercased().wholeMatch(of: /P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:\d+S)?/) else { return nil }
        let days = match.1.flatMap { Int($0) } ?? 0
        let hours = match.2.flatMap { Int($0) } ?? 0
        let minutes = match.3.flatMap { Int($0) } ?? 0
        let total = days * 1440 + hours * 60 + minutes
        return total > 0 ? total : nil
    }

    /// RFC 5545 TEXT escapes.
    static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
