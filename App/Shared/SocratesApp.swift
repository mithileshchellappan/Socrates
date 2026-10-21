import CalendarUI
import CaptureUI
import ChatUI
import CoachUI
import CoursesUI
import FilingUI
import MailUI
import NotesUI
import ReviewUI
import StudyCore
import SwiftUI

@main
struct SocratesApp: App {
    @State private var model: AppModel

    init() {
        #if os(macOS)
        // Reasons and frames of range and consistency exceptions AppKit catches itself.
        ExceptionLog.install()
        #endif
        #if DEBUG && os(macOS)
        ParityMode.prepareApp()
        #endif
        let model = AppModel.launch()
        if let database = model.services?.database {
            prepareDependencies { $0.defaultDatabase = database }
        }
        #if os(iOS)
        // M7: before the first scene, so a Live Activity button that launched the app (Next
        // Slide, Stop Recording) finds the recorder's handler.
        model.phoneRecorder?.activate()
        #endif
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
            #elseif os(iOS)
            // M7: the iPhone's own shell (tab bar, recorder, Today's phone layout); the iPad keeps
            // the split view.
            #if DEBUG
            if PhoneParity.route != nil {
                PhoneParityView(model: model)
            } else {
                phoneOrSplitView
            }
            #else
            phoneOrSplitView
            #endif
            #else
            RootView()
                .environment(model)
            #endif
        }
        .defaultSize(width: 1180, height: 760)
        #if os(macOS)
        // The window's minimum is its columns' declared minimums (RootView's `WindowColumns`),
        // never a screen's content; never `.contentSize`, which pins it to the content's ideal.
        .windowResizability(.contentMinSize)
        #endif
        #if DEBUG && os(macOS)
        .restorationBehavior(ParityMode.options == nil ? .automatic : .disabled)
        #endif
        .commands {
            SidebarCommands()
            InspectorCommands()
            LectureCommands(model: model)
            CourseCommands { model.sheet = .newCourse }
            if let center = model.filingCenter {
                // md: on the Mac, File ▸ Import… opens the Documents importer while Documents shows.
                #if os(macOS)
                AppImportCommands(center: center)
                #else
                ImportCommands(center: center)
                #endif
            }
            GoCommands()
            ReviewCommands()
            // ln: the Lecture menu also holds the lecture notes' Ask… and Highlight (Mac).
            #if os(macOS)
            LiveLectureCommands { LectureNotesMenuItems() }
            #else
            LiveLectureCommands()
            #endif
            // A commands builder takes ten items: the screens' own menus share one group.
            Group {
                MailCommands()
                CalendarCommands()
                // ma: View ▸ Show Chat / Hide Chat ⌘J and Expand Chat / Shrink Chat ⌥⌘J (the agent
                // panel, every screen of the main window), only with Claude Code.
                AgentPanelCommands()
                // Format (M6): the note editor's paragraph styles, lists and marks.
                NoteFormatCommands()
                // mc: Practice (a round's choices, Play Sentence, Next; an exam's Flag, Previous /
                // Next Question, Pause, Submit), published by the round and exam screens.
                PracticeCommands()
            }
        }

        #if os(macOS)
        LiveLectureScene(model: model)
        SettingsScene(model: model)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var phoneOrSplitView: some View {
        if AppModel.isPhone {
            PhoneRootView()
                .environment(model)
        } else {
            RootView()
                .environment(model)
        }
    }
    #endif
}
