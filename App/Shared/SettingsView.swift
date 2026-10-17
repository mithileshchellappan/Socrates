import ClaudeKit
import MailUI
import StudyCore
import StudyUI
import SwiftUI

/// The Settings window's tabs; "Set Up Mail…" opens Accounts.
enum SettingsTab: String, Hashable {
    case semester
    case accounts

    static let storageKey = "StudyPortal.settingsTab"
}

/// Account settings: Claude Code (the AI runs on the student's Claude Code subscription; one quiet
/// row, checked again on appear) and, on the Mac where mail syncs, the uni mail account (its
/// password goes straight to the Keychain).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let value = claudeCodeValue {
                Section {
                    LabeledContent("Claude Code") {
                        value
                            .foregroundStyle(.secondary)
                    }
                }
            }
            #if os(macOS)
            MailAccountSettingsView()
            #endif
        }
        .formStyle(.grouped)
        .disabled(model.services == nil)
        .task { await model.refreshClaudeAvailability() }
    }

    /// The subscription when ready ("Team"), "Paused until 17:20" during a usage pause, "Not
    /// installed", "Not signed in"; nothing on iOS (the AI runs on the Mac) or before the first
    /// check.
    private var claudeCodeValue: Text? {
        switch model.claudeAvailability {
        case .ready(let status)?:
            if let until = status.pausedUntil, until > Date() {
                let time = Text(DayText.time(until)).font(.mono(13))
                return Text("Paused until \(time)")
            }
            if let subscription = status.subscription, !subscription.isEmpty {
                return Text(verbatim: subscription.prefix(1).uppercased() + subscription.dropFirst())
            }
            return status.version.map { Text(verbatim: $0).font(.mono(13)) }
        case .notInstalled?:
            return Text("Not installed")
        case .signedOut?, .missingAPIKey?:
            return Text("Not signed in")
        case .unsupported?, nil:
            return nil
        }
    }
}
