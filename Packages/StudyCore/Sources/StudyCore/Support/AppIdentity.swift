import Foundation

/// The app's identity: its bundle ID (`$(BUNDLE_ID_PREFIX).socrates`, from the build) and the one
/// an earlier build had on this machine before the app was renamed (Study Portal).
///
/// The earlier ID comes from the build's Info.plist (`SocratesLegacyBundleID`, set from
/// `SOCRATES_LEGACY_BUNDLE_ID` in a machine's ignored `Config/Local.xcconfig`; empty in public
/// builds). With it the Mac app takes over, once, what that build left: its library folder
/// (`LibraryMove`), its preferences (`LegacyDefaults`) and its Keychain items
/// (`KeychainSecretStore.legacyServices`: the old Keychain service was that bundle ID).
public enum AppIdentity {
    /// The Info.plist key naming the earlier bundle ID.
    public static let legacyBundleIDInfoKey = "SocratesLegacyBundleID"

    /// This build's bundle ID; "socrates" for a process without one (a command-line tool).
    public static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "socrates"
    }

    /// The bundle ID an earlier build of the app had here, or nil (none named, or the same as
    /// this build's).
    public static func legacyBundleID(bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: legacyBundleIDInfoKey) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$("), trimmed != bundle.bundleIdentifier else { return nil }
        return trimmed
    }
}
