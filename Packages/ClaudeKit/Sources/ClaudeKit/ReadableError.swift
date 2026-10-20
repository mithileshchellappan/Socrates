import Foundation

/// The one sentence the student (or the model, in a tool result) sees for an error. Never the
/// error's own text: SQLite statements, CLI output and Swift type dumps stay in the log, which
/// callers write themselves (type `.public`, content `.private`).
public enum ReadableError {
    /// The default for anything that is not Claude's: a storage failure, most often.
    public static let couldNotSave = String(localized: "The task could not be saved.")
    /// A tool's own failure, as its result tells the model (the tool's data could not be read or
    /// written; the model may try another way).
    public static let toolFailed = "The tool failed; its data could not be read or saved."
    /// A run the student stopped (Stop): the chat keeps what was written and shows no line.
    public static let stopped = String(localized: "Stopped.")

    /// - Parameters:
    ///   - otherwise: the sentence for an error that is not Claude's (default `couldNotSave`).
    ///   - retrying: the caller tries again by itself after the service's trouble (the sub-agent
    ///     queue); false (the panel's answers, never retried): "Claude is busy." alone.
    ///   - now: for a usage pause's "until" (the weekday is added when it is not today).
    public static func sentence(
        for error: any Error, otherwise: String = couldNotSave, retrying: Bool = true, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        if error is CancellationError { return stopped }
        guard let error = error as? ClaudeError else { return otherwise }
        let busy = retrying ? String(localized: "Claude is busy; trying again later.") : String(localized: "Claude is busy.")
        switch error {
        case .unavailable(.signedOut), .authentication, .missingAPIKey, .unavailable(.missingAPIKey):
            return String(localized: "Claude Code is signed out.")
        case .unavailable(.notInstalled):
            return String(localized: "Claude Code is not installed.")
        case .unavailable(.unsupported):
            return String(localized: "Claude does not run on this device.")
        case .usageLimited(let resetsAt):
            return paused(until: resetsAt, now: now, calendar: calendar)
        case .claudeCodeProcess:
            return String(localized: "Claude Code stopped unexpectedly.")
        case .stalled(let idle):
            let minutes = max(1, Int(idle.components.seconds / 60))
            return String(localized: "Claude Code sent nothing for \(minutes) minutes and was stopped.")
        case .transport, .overloaded, .rateLimited, .server, .streamEndedUnexpectedly:
            return busy
        case .refused:
            return String(localized: "The model declined to answer.")
        case .truncated:
            return String(localized: "The answer was cut off.")
        case .turnLimit:
            return String(localized: "Stopped after too many steps.")
        default:
            return error.isServiceTrouble ? busy : otherwise
        }
    }

    /// "Paused until 17:20", or "Paused until Tue 17:20" when the reset is not today: 24-hour,
    /// whatever the region, as the app writes every clock time.
    public static func paused(until date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return String(localized: "Paused until the usage limit resets.") }
        let format: Date.FormatString
        if calendar.isDate(date, inSameDayAs: now) {
            format = "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"
        } else {
            format = "\(weekday: .abbreviated) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"
        }
        let style = Date.VerbatimFormatStyle(
            format: format, locale: calendar.locale ?? .current, timeZone: calendar.timeZone, calendar: Calendar(identifier: .gregorian)
        )
        let time = date.formatted(style)
        return String(localized: "Paused until \(time)")
    }

    /// The error's type, for the log at `.public` privacy (never its content).
    public static func kind(of error: any Error) -> String {
        if let error = error as? ClaudeError {
            // The case name only (a payload-less case's description is fixed text).
            return "ClaudeError." + (Mirror(reflecting: error).children.first?.label ?? error.description)
        }
        return String(reflecting: type(of: error))
    }
}
