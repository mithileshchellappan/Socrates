import ClaudeKit
import MailUI
import StudyCore
import StudyUI
import SwiftUI
import Sync

/// The Settings window's tabs; "Set Up Mail…" opens Accounts.
enum SettingsTab: String, Hashable {
    case semester
    case accounts

    static let storageKey = "StudyPortal.settingsTab"
}

/// Account settings: Claude Code (the AI runs on the student's Claude Code subscription; one quiet
/// row, checked again on appear), iCloud (M7: only in a build that syncs; what has not reached
/// iCloud yet, counted every 5 s while the row shows) and, on the Mac where mail syncs, the uni
/// mail account (its password goes straight to the Keychain).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if claudeCodeValue != nil || iCloudValue != nil {
                Section {
                    if let value = claudeCodeValue {
                        LabeledContent("Claude Code") {
                            value
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let value = iCloudValue {
                        LabeledContent("iCloud") {
                            value
                                .foregroundStyle(.secondary)
                        }
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
        .task(id: model.cloudSync?.isRunning) {
            guard let sync = model.cloudSync, sync.isRunning else { return }
            while !Task.isCancelled {
                await sync.refreshUnsent()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// M7: "Up to date", "Syncing", "12,480 to upload" (the Mac's first upload), "3 not uploaded"
    /// (rows iCloud refused, e.g. over its 1 MB record size), or why sync is off ("Not signed in
    /// to iCloud"); nothing in a build without sync or before it started.
    private var iCloudValue: Text? {
        guard let sync = model.cloudSync else { return nil }
        switch sync.status {
        case .running:
            let unsent = sync.unsentCount ?? 0
            if unsent > 0 {
                let count = Text(unsent, format: .number).font(.mono(13))
                return sync.isSynchronizing ? Text("\(count) to upload") : Text("\(count) not uploaded")
            }
            return sync.isSynchronizing ? Text("Syncing") : Text("Up to date")
        case .unavailable(let reason), .failed(let reason):
            return Text(verbatim: reason)
        case .idle, .starting:
            return nil
        }
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
