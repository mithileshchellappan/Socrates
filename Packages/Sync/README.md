# Sync

iCloud sync of the library (M7, docs/plan-m7.md §4, §5.1): `CloudSync`, SQLiteData's `SyncEngine`
over the library tables, behind `CloudSyncConfiguration` (StudyCore): it exists only in a build
signed with the iCloud entitlement that names its container in the Info.plist
(`StudyPortalCloudKitContainer`). Every build this Mac can make today (no "Apple Development"
identity) has none, so sync is compiled but never runs.

Status: skeleton landed with the plan (contracts only). Workstream A replaces this README.
