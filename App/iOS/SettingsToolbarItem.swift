import CoursesUI
import StudyUI
import SwiftUI

/// iOS/iPadOS has no Settings scene: a toolbar button presents the same settings in a sheet.
struct SettingsToolbarItem: ToolbarContent {
    @State private var isPresented = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { isPresented = true }
                .sheet(isPresented: $isPresented) {
                    SettingsSheet()
                }
        }
    }
}

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Semester") {
                    SemesterSettingsView()
                        .navigationTitle("Semester")
                }
                NavigationLink("Accounts") {
                    SettingsView()
                        .navigationTitle("Accounts")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .environment(\.studyServices, model.services)
        .environment(\.calendarMirror, model.calendarMirror)
    }
}
