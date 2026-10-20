import AppKit
import StudyCore

/// The Mac app taking over, once, what the build from before the rename (Study Portal, another
/// bundle ID) left: its preferences (`LegacyDefaults`) and its library folder (`LibraryMove`).
/// Its Keychain items move on first read (`KeychainSecretStore`). Runs at launch before the
/// library opens, for the real library only (never under `SOCRATES_DATA_ROOT`, never in parity
/// or snapshot runs, which return before it).
enum LegacyTakeover {
    static func run() {
        guard AppPaths.rootOverride() == nil else { return }
        let legacyBundleID = AppIdentity.legacyBundleID()
        LegacyDefaults.importOnce(from: legacyBundleID)
        _ = LibraryMove.run(legacyBundleID: legacyBundleID, isLegacyAppRunning: {
            // The earlier app has the library open: it stays where it is this launch. Without an
            // earlier bundle ID (public builds) there is nothing to ask.
            guard let legacyBundleID else { return false }
            return !NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).isEmpty
        })
    }
}
