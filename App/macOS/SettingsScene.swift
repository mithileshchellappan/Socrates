import SwiftUI

/// The macOS Settings window (⌘,).
struct SettingsScene: Scene {
    let model: AppModel

    var body: some Scene {
        Settings {
            TabView {
                Tab("Accounts", systemImage: "person.crop.circle") {
                    SettingsView()
                }
            }
            .frame(width: 480)
            .environment(model)
        }
    }
}
