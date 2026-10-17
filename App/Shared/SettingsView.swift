import MailUI
import StudyCore
import SwiftUI

/// The Settings window's tabs; "Set Up Mail…" opens Accounts.
enum SettingsTab: String, Hashable {
    case semester
    case accounts

    static let storageKey = "StudyPortal.settingsTab"
}

/// Account settings: the Claude API key and (on the Mac, where mail syncs) the uni mail account.
/// The key and the password go straight to the Keychain and are never shown again.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var isStored = false
    @State private var failure: String?

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section("Claude") {
                SecureField(
                    "API Key",
                    text: $draft,
                    prompt: Text(isStored ? "••••••••••••••••" : "sk-ant-…")
                )
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit(save)

                HStack {
                    if isStored {
                        Button("Remove", role: .destructive, action: remove)
                    }
                    Spacer()
                    // Filled only while there is a key to save: the window keeps one filled button.
                    if trimmedDraft.isEmpty {
                        Button("Save", action: save)
                            .disabled(true)
                    } else {
                        Button("Save", action: save)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            #if os(macOS)
            MailAccountSettingsView()
            #endif
        }
        .formStyle(.grouped)
        .disabled(model.services == nil)
        .onAppear { isStored = model.hasAPIKey }
        .alert(
            "Keychain",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        do {
            try model.storeAPIKey(trimmedDraft)
            draft = ""
            isStored = true
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try model.removeAPIKey()
            isStored = false
        } catch {
            failure = error.localizedDescription
        }
    }
}
