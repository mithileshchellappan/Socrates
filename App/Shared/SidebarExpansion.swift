import Foundation
import StudyCore

/// Which parts of the sidebar's course tree are open (DESIGN 6.2): the courses that list their
/// screens, and the courses whose Lectures row lists their lectures and next class. Kept per
/// window (`SceneStorage`) and the same on every screen: only the chevrons, ← and →, and opening a
/// lecture change it, never the screen on display.
struct SidebarExpansion: Equatable, RawRepresentable {
    /// The courses that list their screens.
    private(set) var openCourses: Set<Course.ID> = []
    /// The courses whose Lectures row is open (it lists its rows while its course is open too).
    private(set) var openLectureRows: Set<Course.ID> = []

    init() {}

    /// Renders: a window that opens with these parts open.
    init(openCourses: Set<Course.ID>, openLectureRows: Set<Course.ID> = []) {
        self.openCourses = openCourses
        self.openLectureRows = openLectureRows
    }

    func showsScreens(of course: Course.ID) -> Bool {
        openCourses.contains(course)
    }

    /// Whether a course's Lectures row is open and lists its rows: only while its course is open
    /// and it has rows (without any it has no chevron, so it is never open). The one place this is
    /// decided: the chevron, the rows under it, ← → and the row that marks a lecture use it.
    func showsLectures(of course: Course.ID, hasRows: Bool) -> Bool {
        hasRows && openCourses.contains(course) && openLectureRows.contains(course)
    }

    mutating func setScreens(of course: Course.ID, shown: Bool) {
        if shown { openCourses.insert(course) } else { openCourses.remove(course) }
    }

    mutating func setLectures(of course: Course.ID, shown: Bool) {
        if shown { openLectureRows.insert(course) } else { openLectureRows.remove(course) }
    }

    /// Opening a lecture opens its course and its Lectures row, so the lecture's row shows.
    mutating func reveal(lecturesOf course: Course.ID) {
        openCourses.insert(course)
        openLectureRows.insert(course)
    }

    // MARK: - RawRepresentable

    /// "<open courses>|<open Lectures rows>", each a comma-separated list of IDs. Before the tree a
    /// window kept only the courses that listed their lectures ("<courses>"): they open with their
    /// Lectures row open, so the same lectures show.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", omittingEmptySubsequences: false)
        let courses = Self.ids(parts.first ?? "")
        openCourses = courses
        openLectureRows = parts.count > 1 ? Self.ids(parts[1]) : courses
    }

    var rawValue: String {
        "\(Self.text(openCourses))|\(Self.text(openLectureRows))"
    }

    private static func ids(_ text: Substring) -> Set<Course.ID> {
        Set(text.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private static func text(_ ids: Set<Course.ID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }
}
