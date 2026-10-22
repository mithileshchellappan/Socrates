import Foundation
import StudyCore

/// Which parts of the sidebar's course tree are open (DESIGN 6.2): the courses that list their
/// screens, and the courses whose Lectures row lists their lectures and next class. Kept per
/// window (`SceneStorage`) and the same on every screen: only the chevrons, ← and →, and opening a
/// lecture change it, never the screen on display.
struct SidebarExpansion: Equatable, RawRepresentable {
    /// The courses that list their screens.
    private(set) var courses: Set<Course.ID> = []
    /// The courses whose Lectures row is open (it shows while its course is open too).
    private(set) var lectures: Set<Course.ID> = []

    init() {}

    /// Renders: a window that opens with these parts open.
    init(courses: Set<Course.ID>, lectures: Set<Course.ID> = []) {
        self.courses = courses
        self.lectures = lectures
    }

    func showsScreens(of course: Course.ID) -> Bool {
        courses.contains(course)
    }

    func showsLectures(of course: Course.ID) -> Bool {
        courses.contains(course) && lectures.contains(course)
    }

    mutating func setScreens(of course: Course.ID, shown: Bool) {
        if shown { courses.insert(course) } else { courses.remove(course) }
    }

    mutating func setLectures(of course: Course.ID, shown: Bool) {
        if shown { lectures.insert(course) } else { lectures.remove(course) }
    }

    /// Opening a lecture opens its course and its Lectures row, so the lecture's row shows.
    mutating func reveal(lecturesOf course: Course.ID) {
        courses.insert(course)
        lectures.insert(course)
    }

    // MARK: - RawRepresentable

    /// "<courses>|<lectures>", each a comma-separated list of IDs. Before the tree a window kept
    /// only the courses that listed their lectures ("<courses>"): they open with their Lectures row
    /// open, so the same lectures show.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", omittingEmptySubsequences: false)
        let courses = Self.ids(parts.first ?? "")
        self.courses = courses
        lectures = parts.count > 1 ? Self.ids(parts[1]) : courses
    }

    var rawValue: String {
        "\(Self.text(courses))|\(Self.text(lectures))"
    }

    private static func ids(_ text: Substring) -> Set<Course.ID> {
        Set(text.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private static func text(_ ids: Set<Course.ID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }
}
