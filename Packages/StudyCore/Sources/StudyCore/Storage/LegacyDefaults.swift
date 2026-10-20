import CoreFoundation
import Foundation

/// The Mac's one-time copy of the preferences an earlier build left under its bundle ID (the app
/// was Study Portal): the Settings tab, the review layout, recent searches, the agent panel's
/// width, which calendars show, the calendar mirror's own calendar, window frames.
///
/// Only that domain's own keys are read (`CFPreferencesCopyKeyList`, not the global domain the
/// suite would add); a key this build has already set keeps its value; "StudyPortal" in a key
/// becomes "Socrates" (the keys were renamed with the app). Done once, marked by
/// `markerKey`; the earlier domain is left as it is. Works because the Mac app is unsandboxed.
public enum LegacyDefaults {
    /// Set once the copy ran (also when there was nothing to copy).
    public static let markerKey = "Socrates.importedLegacyDefaults"

    /// Copies the preferences of `legacyBundleID` into this app's standard defaults, once.
    /// Returns how many keys were copied.
    @discardableResult
    public static func importOnce(from legacyBundleID: String?) -> Int {
        let defaults = UserDefaults.standard
        guard let legacyBundleID, legacyBundleID != AppIdentity.bundleID, !defaults.bool(forKey: markerKey) else { return 0 }
        let domain = legacyBundleID as CFString
        let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        var copied = 0
        if !keys.isEmpty,
           let values = CFPreferencesCopyMultiple(keys as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] {
            let own = defaults.persistentDomain(forName: AppIdentity.bundleID) ?? [:]
            for (key, value) in values {
                let renamed = key.replacingOccurrences(of: "StudyPortal", with: "Socrates")
                guard own[renamed] == nil else { continue }
                defaults.set(value, forKey: renamed)
                copied += 1
            }
        }
        defaults.set(true, forKey: markerKey)
        Log.app.notice("Took over \(copied, privacy: .public) preferences of the earlier build")
        return copied
    }
}
