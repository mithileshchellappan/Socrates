#if os(macOS)
import Foundation

/// How a tool-loop run keeps the student's Claude Code setup out (docs/plan-m35.md §3.5).
enum IsolationVariant: String, Codable, Sendable, CaseIterable {
    /// `--safe-mode`: CLAUDE.md, hooks, plugins, skills and MCP servers off.
    case safeMode = "safe_mode"
    /// `--setting-sources ""`: no user, project or local settings (used when `--safe-mode` also
    /// drops the app's `--mcp-config` server).
    case noSettingSources = "no_setting_sources"

    var arguments: [String] {
        switch self {
        case .safeMode: ["--safe-mode"]
        case .noSettingSources: ["--setting-sources", ""]
        }
    }

    var other: IsolationVariant {
        self == .safeMode ? .noSettingSources : .safeMode
    }
}

/// `Agent/state.json`: survives relaunches.
struct ClaudeCodeState: Codable, Sendable, Equatable {
    /// A usage limit was hit; calls wait (background) or fail (interactive) until then.
    var pausedUntil: Date?
    /// The isolation variant whose `system/init` passed, per CLI version ("2.1.268").
    var isolation: [String: IsolationVariant] = [:]

    static func load(from url: URL) -> ClaudeCodeState {
        guard let data = try? Data(contentsOf: url) else { return ClaudeCodeState() }
        do {
            return try decoder.decode(ClaudeCodeState.self, from: data)
        } catch {
            ClaudeClient.logger.error("Claude Code state unreadable, starting fresh: \(String(describing: error), privacy: .public)")
            return ClaudeCodeState()
        }
    }

    func save(to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            ClaudeClient.logger.error("Claude Code state not saved: \(String(describing: error), privacy: .public)")
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Reads the CLI's usage-limit messages (docs/plan-m35.md §3.6).
enum UsageLimitText {
    /// Whether `text` says a subscription limit was hit ("You've hit your session limit · resets
    /// 5:20pm (Europe/Lisbon)", "…weekly limit…", "Claude AI usage limit reached|…").
    static func isLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return (lower.contains("hit your") && lower.contains("limit")) || lower.contains("usage limit reached")
    }

    /// The reset time a limit message states: "resets 5:20pm (Europe/Lisbon)", "resets 5pm",
    /// "resets Oct 20, 5pm (Europe/Lisbon)", "resets 17:20"; the next such time after `now` in the
    /// stated zone (else the Mac's). A trailing "|<epoch seconds>" (older CLIs) wins. Nil when
    /// the text names no time.
    static func resetDate(in text: String, now: Date) -> Date? {
        if let bar = text.lastIndex(of: "|"),
           let seconds = TimeInterval(text[text.index(after: bar)...].trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let resets = text.range(of: "resets", options: .caseInsensitive) else { return nil }
        var rest = String(text[resets.upperBound...])
        var zone = TimeZone.current
        if let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let identifier = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if let named = TimeZone(identifier: identifier) ?? TimeZone(abbreviation: identifier) { zone = named }
            rest = String(rest[..<open])
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".·")))

        let timePattern = #/(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<meridiem>[ap]\.?m\.?)?/#.ignoresCase()
        guard let time = rest.matches(of: timePattern).last, var hour = Int(time.output.hour) else { return nil }
        let minute = time.output.minute.flatMap { Int($0) } ?? 0
        if let meridiem = time.output.meridiem?.lowercased() {
            if meridiem.hasPrefix("p"), hour < 12 { hour += 12 }
            if meridiem.hasPrefix("a"), hour == 12 { hour = 0 }
        }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let datePattern = #/(?<month>[A-Za-z]{3})[a-z]*\.?\s+(?<day>\d{1,2})\b/#
        if let date = rest.firstMatch(of: datePattern),
           let month = months.firstIndex(of: date.output.month.lowercased()), let day = Int(date.output.day) {
            var components = DateComponents(month: month + 1, day: day, hour: hour, minute: minute)
            components.year = calendar.component(.year, from: now)
            guard var candidate = calendar.date(from: components) else { return nil }
            if candidate < now.addingTimeInterval(-86_400) {
                components.year = (components.year ?? 0) + 1
                candidate = calendar.date(from: components) ?? candidate
            }
            return candidate
        }
        return calendar.nextDate(
            after: now, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
    }
}
#endif
