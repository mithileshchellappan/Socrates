import Foundation

/// Whether this build syncs the library through iCloud (M7, docs/plan-m7.md §4).
///
/// Sync needs a build signed with the iCloud (CloudKit) entitlement for its container; such a
/// build also names the container in its Info.plist under `StudyPortalCloudKitContainer`. Both
/// come from the same build settings (`STUDYPORTAL_ICLOUD = YES` in Config/Local.xcconfig: the
/// container `iCloud.<bundle ID prefix>.studyportal`, the iCloud entitlements files), so they
/// ship together. Builds without it (no team, ad hoc, every simulator build) have neither:
/// `containerIdentifier()` is nil, nothing about sync runs (no CloudKit call, which would trap
/// without the entitlement) and the database opens exactly as before.
public enum CloudSyncConfiguration {
    /// The Info.plist key a signed build sets to its CloudKit container ("iCloud.com.yourname.studyportal").
    public static let infoKey = "StudyPortalCloudKitContainer"

    /// The CloudKit container this build syncs to, or nil: sync off.
    public static func containerIdentifier(bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: infoKey) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("iCloud.") ? trimmed : nil
    }
}
