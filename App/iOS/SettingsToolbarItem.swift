import SwiftUI

/// iOS/iPadOS has no Settings scene: a toolbar button presents the same form in a sheet.
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

    var body: some View {
        NavigationStack {
            SettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
    }
}
