import StudyCore
import SwiftUI

/// A course picked from the library, or a new one typed in place (course setup is M1).
enum CourseChoice: Hashable {
    case existing(Course.ID)
    case new
}

/// Course picker plus, for a new course, its name and language.
struct CourseChoiceSection: View {
    let courses: [Course]
    @Binding var choice: CourseChoice
    @Binding var draft: CourseDraft
    @FocusState private var nameFocused: Bool

    var body: some View {
        Picker("Course", selection: $choice) {
            ForEach(courses) { course in
                Text(course.name).tag(CourseChoice.existing(course.id))
            }
            if !courses.isEmpty { Divider() }
            Text("New Course").tag(CourseChoice.new)
        }
        if choice == .new {
            TextField("Name", text: $draft.name, prompt: Text("Computational Linguistics"))
                .focused($nameFocused)
                .onAppear { nameFocused = courses.isEmpty }
            Picker("Language", selection: $draft.language) {
                ForEach(CourseDraft.languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
        }
    }

    /// The choice to start with: `preferred`, else the first course, else a new one.
    static func initial(courses: [Course], preferred: Course.ID?) -> CourseChoice {
        if let preferred, courses.contains(where: { $0.id == preferred }) { return .existing(preferred) }
        return courses.first.map { .existing($0.id) } ?? .new
    }
}

extension CourseChoice {
    func course(in courses: [Course]) -> Course? {
        guard case .existing(let id) = self else { return nil }
        return courses.first { $0.id == id }
    }
}
