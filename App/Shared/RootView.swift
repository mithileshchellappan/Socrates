import Processing
import StudyCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var selection: SidebarItem? = .today
    @State private var query = ""

    var body: some View {
        @Bindable var model = model
        if let launchError = model.launchError {
            ContentUnavailableView(
                "Library unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(launchError)
            )
        } else {
            NavigationSplitView {
                SidebarView(selection: $selection)
            } detail: {
                NavigationStack {
                    DetailView(item: selection ?? .today)
                }
                .id(selection)
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Search lectures, notes, mail")
            .onSubmit(of: .search) { selection = .search }
            .focusedSceneValue(\.sidebarSelection, $selection)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Record", systemImage: "record.circle", action: record)
                        .labelStyle(.titleAndIcon)
                }
            }
            .sheet(item: $model.sheet) { sheet in
                switch sheet {
                case .newCapture:
                    CaptureSetupView()
                case .importLecture(let courseID):
                    ImportLectureView(preferredCourseID: courseID) { imported in
                        selection = .course(imported.lecture.courseID)
                    }
                }
            }
            .alert(
                "Couldn’t finish",
                isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
                presenting: model.failure
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $model.isLivePresented, onDismiss: { model.closeLiveLecture() }) {
                NavigationStack {
                    LiveLectureScreen()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(role: .close) { model.isLivePresented = false }
                            }
                        }
                }
                .environment(model)
            }
            #endif
            .task { await model.startBackgroundWork() }
        }
    }

    /// Shows the running live lecture, or sets up a new one.
    private func record() {
        guard model.live != nil else {
            model.sheet = .newCapture
            return
        }
        #if os(macOS)
        openWindow(id: LiveLectureScene.id)
        #else
        model.isLivePresented = true
        #endif
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @FetchAll(Course.order { ($0.sortOrder, $0.name) }) private var courses

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.destinations, id: \.self) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }

            Section("Courses") {
                ForEach(courses) { course in
                    NavigationLink(value: SidebarItem.course(course.id)) {
                        Label {
                            Text(course.name)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .imageScale(.small)
                                .foregroundStyle(Color(hex: course.colorHex) ?? .accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Study Portal")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        #else
        .toolbar { SettingsToolbarItem() }
        #endif
    }
}
