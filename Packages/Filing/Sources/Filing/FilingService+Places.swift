import Foundation
import StudyCore

extension FilingService {
    /// Where a filing put its file, ready to show; nil while it has no course.
    public func place(of filing: Filing) async throws -> FilingPlace? {
        Self.place(of: filing, library: try await loadLibrary())
    }

    static func place(of filing: Filing, library: FilingLibrary) -> FilingPlace? {
        let matcher = FilingMatcher(library: library)
        if let id = filing.lectureID, let info = library.lecture(id), let course = library.course(info.lecture.courseID) {
            var place = matcher.lectureChoice(info, course: course, fit: filing.confidence, signals: []).place
            if let sessionID = info.lecture.lectureSessionID, let session = library.session(sessionID) {
                place.date = session.startsAt
                place.isWholeDay = false
                place.number = info.lecture.number ?? session.number
                place.sessionKind = session.kind
            }
            return place
        }
        if let id = filing.courseID, let course = library.course(id) {
            return FilingPlace(course: course, isCourseOnly: true, destination: .course(id), confidence: filing.confidence)
        }
        return nil
    }

    /// The courses, in sidebar order.
    public func courses() async throws -> [Course] {
        try await loadLibrary().courses
    }

    /// Where a file can go in a course: its lectures and the sessions without one (past and
    /// upcoming), in time order; undated lectures last.
    public func places(courseID: Course.ID) async throws -> [FilingPlace] {
        let library = try await loadLibrary()
        guard let course = library.course(courseID) else { return [] }
        let matcher = FilingMatcher(library: library)
        var places = library.lectures(courseID: courseID).map { info in
            if let sessionID = info.lecture.lectureSessionID, let session = library.session(sessionID) {
                return matcher.sessionChoice(session, course: course, fit: 1, signals: []).place
            }
            return matcher.lectureChoice(info, course: course, fit: 1, signals: []).place
        }
        for session in library.sessions(courseID: courseID) where library.lecture(sessionID: session.id) == nil {
            places.append(matcher.sessionChoice(session, course: course, fit: 1, signals: []).place)
        }
        return places.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?): left < right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): (lhs.number ?? .max) < (rhs.number ?? .max)
            }
        }
    }

    /// The filing, if it still exists.
    public func filing(_ id: Filing.ID) async throws -> Filing? {
        try await store.fetch(Filing.self, id: id)
    }
}
