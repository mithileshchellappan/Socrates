import CaptureUI
import StudyCore
import SwiftUI

@main
struct StudyPortalApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel.launch()
        if let database = model.services?.database {
            prepareDependencies { $0.defaultDatabase = database }
        }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            SidebarCommands()
            InspectorCommands()
            LectureCommands(model: model)
            GoCommands()
            LiveLectureCommands()
        }

        #if os(macOS)
        LiveLectureScene(model: model)
        SettingsScene(model: model)
        #endif
    }
}
