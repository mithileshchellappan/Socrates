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
}
