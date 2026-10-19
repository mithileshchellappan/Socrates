import Courses
import Foundation
import StudyCore
import os

/// The recorder's names for a recording (DESIGN 9).
public enum RecorderText {
    /// "Tue 13 Oct".
    public static func day(_ date: Date) -> String {
        SessionText().day(date)
    }

    /// The session's name as Calendar writes it, with the short name: "DC Lecture 2", "DC
    /// exercise"; without a known class the short name and the day, "DC Tue 13 Oct".
    public static func sessionName(course: Course, session: LectureSession?, day date: Date) -> String {
        let short = course.shortName.trimmingCharacters(in: .whitespaces)
        let name = short.isEmpty ? course.name : short
        if let session {
            return SessionText.title(of: session, courseName: name)
        }
        return "\(name) \(day(date))"
    }

    /// The line under the timer: "Lecture 2 · Tue 13 Oct", "Exercise · Tue 20 Oct"; the day alone
    /// without a known class.
    public static func sessionLine(session: LectureSession?, day date: Date) -> String {
        guard let session else { return day(date) }
        let kind = session.kind == .lecture && session.number != nil
            ? String(localized: "Lecture \(session.number ?? 0)")
            : session.kind.displayName
        return "\(kind) · \(day(date))"
    }
}

enum RecorderLog {
    static let recorder = Log.logger(category: "recorder")
}
