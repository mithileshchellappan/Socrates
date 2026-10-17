import CoursesUI
import StudyUI
import SwiftUI

/// The macOS Settings window (⌘,).
struct SettingsScene: Scene {
    let model: AppModel

    var body: some Scene {
        Settings {
            TabView {
                Tab("Semester", systemImage: "calendar") {
                    SemesterSettingsView()
                }
                Tab("Accounts", systemImage: "person.crop.circle") {
                    SettingsView()
                }
            }
            .frame(width: 520)
            .environment(model)
            .environment(\.studyServices, model.services)
            .environment(\.calendarMirror, model.calendarMirror)
        }
    }
}
