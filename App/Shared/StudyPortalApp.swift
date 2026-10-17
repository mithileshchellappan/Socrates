import CaptureUI
import CoursesUI
import FilingUI
import MailUI
import ReviewUI
import StudyCore
import SwiftUI

@main
struct StudyPortalApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG && os(macOS)
        ParityMode.prepareApp()
        #endif
        let model = AppModel.launch()
        if let database = model.services?.database {
            prepareDependencies { $0.defaultDatabase = database }
        }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup(id: MainWindow.id) {
            #if DEBUG && os(macOS)
            if SnapshotRunner.directory != nil {
                SnapshotRunnerView(model: model)
            } else if ParityMode.options != nil {
                ParityRootView(model: model)
            } else {
                RootView()
                    .environment(model)
            }
            #else
            RootView()
                .environment(model)
            #endif
        }
        .defaultSize(width: 1180, height: 760)
        #if DEBUG && os(macOS)
        .restorationBehavior(ParityMode.options == nil ? .automatic : .disabled)
        #endif
        .commands {
            SidebarCommands()
            InspectorCommands()
            LectureCommands(model: model)
            CourseCommands { model.sheet = .newCourse }
            if let center = model.filingCenter {
                ImportCommands(center: center)
            }
            GoCommands()
            ReviewCommands()
            LiveLectureCommands()
            MailCommands()
        }

        #if os(macOS)
        LiveLectureScene(model: model)
        SettingsScene(model: model)
        #endif
    }
}
