import Agent
import ClaudeKit
import CryptoKit
import Deadlines
import Foundation
import os
import StudyCore

/// The one app agent (milestone ma, docs/plan-agent.md). Logs through
/// `Log.logger(category: "app-agent")`; never logs the student's words, quotes, mail or
/// transcript text at `.public`.
public enum AppAgentModule {
    public static let moduleName = "AppAgent"

    /// `api_call.purpose` values of the app agent's calls.
    public enum Purpose {
        /// The panel's conversation (`ConversationKind.app`): Opus 5.5, effort medium.
        public static let app = AgentModule.purpose(of: .app)
        /// A sub-agent task's conversation (`ConversationKind.task`).
        public static let task = AgentModule.purpose(of: .task)
        /// The batched Haiku triage of new facts.
        public static let triage = "agent.triage"
    }

    static let log = Log.logger(category: "app-agent")
    static var timeZone: TimeZone { DeadlinesModule.timeZone }
}

/// Tool results: compact JSON (sorted keys) of at most `limit` characters.
enum ToolJSON {
    static let limit = 4_000

    /// `base` with `rows` under `key`, as many as fit (then `"more": n`).
    static func fitted(_ base: JSONObject, key: String, rows: [JSONValue]) -> ToolOutput {
        var count = rows.count
        while true {
            var object = base
            object[key] = .array(Array(rows.prefix(count)))
            if count < rows.count { object["more"] = .int(rows.count - count) }
            let text = (try? JSONValue.object(object).serializedString()) ?? "{}"
            if text.count <= limit { return .text(text) }
            guard count > 0 else { return .error("The result is too long; ask for less.") }
            let average = max(1, text.count / max(count, 1))
            count = max(0, count - max(1, (text.count - limit) / average))
        }
    }

    static func object(_ object: JSONObject) -> ToolOutput {
        let text = (try? JSONValue.object(object).serializedString()) ?? "{}"
        return text.count <= limit ? .text(text) : .error("The result is too long; ask for less.")
    }

    static func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

    static func id(_ id: UUID?) -> JSONValue { id.map { .string($0.uuidString.lowercased()) } ?? .null }

    /// At most `count` characters, "…" when cut; whitespace runs as one space.
    static func clip(_ text: String, _ count: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > count else { return flat }
        return String(flat.prefix(max(0, count - 1))) + "…"
    }
}

/// Dates as the app agent writes them for a model (the university's time zone).
enum AgentText {
    static var timeZone: TimeZone { AppAgentModule.timeZone }

    /// "Tue 20 Oct, 12:15" (or the day alone).
    static func dayTime(_ date: Date, allDay: Bool = false) -> String { ChangeSummary.dayTime(date, allDay: allDay) }

    /// "Thu 22 Oct".
    static func day(_ date: Date) -> String { ChangeSummary.day(date) }

    /// "2026-10-20T12:15" / "2026-10-22".
    static func iso(_ date: Date?, allDay: Bool = false) -> String? { AgentToolSupport.dateText(date, allDay: allDay) }

    /// "29:44" / "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The first 8 hex of the SHA-256 of `text` (block revisions).
    static func revision(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}

extension ToolUseBlock {
    func text(_ key: String) -> String? { trimmedString(key) }

    func flag(_ key: String) -> Bool? { boolean(key) }

    func id(_ key: String) -> UUID? {
        guard let text = text(key) else { return nil }
        return UUID(uuidString: text)
    }

    func integer(_ key: String) -> Int? {
        if let value = input[key]?.intValue { return value }
        if let value = input[key]?.doubleValue, value.rounded() == value { return Int(value) }
        return nil
    }

    func number(_ key: String) -> Double? { input[key]?.doubleValue ?? input[key]?.intValue.map(Double.init) }

    func strings(_ key: String) -> [String] {
        guard case .array(let values)? = input[key] else { return [] }
        return values.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// Schemas of strict tool inputs.
enum Schema {
    static func object(_ properties: JSONObject) -> JSONValue { AgentToolSupport.object(properties) }
    static func nullable(_ schema: JSONValue) -> JSONValue { AgentToolSupport.nullable(schema) }
    static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    static func optionalString(_ description: String) -> JSONValue { nullable(string(description)) }
    static func stringEnum(_ values: [String]) -> JSONValue { ["type": "string", "enum": .array(values.map(JSONValue.string))] }
}
