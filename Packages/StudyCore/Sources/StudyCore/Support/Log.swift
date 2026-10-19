import os

/// `os.Logger`s, one category per module. Use these instead of `print`.
///
/// Never log secrets, mail bodies or transcript text at `.public` privacy.
public enum Log {
    public static let subsystem = "com.example.studyportal"

    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static let app = logger(category: "app")
    public static let database = logger(category: "database")
    public static let blobs = logger(category: "blobs")
    public static let keychain = logger(category: "keychain")
    public static let capture = logger(category: "capture")
    public static let transcription = logger(category: "transcription")
    public static let alignment = logger(category: "alignment")
    public static let claude = logger(category: "claude")
    public static let mail = logger(category: "mail")
    public static let calendar = logger(category: "calendar")
    public static let importer = logger(category: "import")
    public static let search = logger(category: "search")
    public static let jobs = logger(category: "jobs")

    /// A state-machine write (a task or job row moving on: finish, pause) that must not fail
    /// silently: a failure is logged and the write tried once more after a moment. Nil when both
    /// tries failed (the row is then recovered at the next launch). `what` is public log text
    /// ("finishing task 1a2b…"), never content.
    @discardableResult
    public static func retryingOnce<T>(
        _ what: String, logger: Logger, isolation: isolated (any Actor)? = #isolation, _ write: () async throws -> T
    ) async -> T? {
        for attempt in 1...2 {
            do {
                return try await write()
            } catch {
                logger.error(
                    "\(what, privacy: .public) failed (try \(attempt) of 2): \(String(reflecting: type(of: error)), privacy: .public): \(String(describing: error), privacy: .private)"
                )
                if attempt == 1 { try? await Task.sleep(for: .milliseconds(250)) }
            }
        }
        return nil
    }
}
