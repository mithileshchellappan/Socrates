import CoursesUI
import MailUI
import StudyUI
import SwiftUI

/// The macOS Settings window (⌘,): Semester, and Accounts (Claude Code and the uni mail account).
struct SettingsScene: Scene {
    let model: AppModel
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.semester

    var body: some Scene {
        Settings {
            TabView(selection: $tab) {
                Tab("Semester", systemImage: "calendar", value: SettingsTab.semester) {
                    SemesterSettingsView()
                }
                Tab("Accounts", systemImage: "person.crop.circle", value: SettingsTab.accounts) {
                    SettingsView()
                }
            }
            .frame(width: 520)
            .environment(model)
            .environment(\.studyServices, model.services)
            .environment(\.calendarMirror, model.calendarMirror)
            .environment(\.mailActions, model.mailActions)
        }
    }
}
