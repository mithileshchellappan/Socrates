import StudyCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .today
    @State private var query = ""

    var body: some View {
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
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Search lectures, notes, mail")
            .onSubmit(of: .search) { selection = .search }
            .focusedSceneValue(\.sidebarSelection, $selection)
        }
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
