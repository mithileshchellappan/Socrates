# Sync

iCloud sync of the library (M7, docs/plan-m7.md §4, §5.1): `CloudSync`, SQLiteData's `SyncEngine`
over the library tables, behind `CloudSyncConfiguration` (StudyCore): it exists only in a build
signed with the iCloud entitlement that names its container in the Info.plist
(`StudyPortalCloudKitContainer`). Every build this Mac can make today (no "Apple Development"
identity) has none, so sync is compiled but never runs, and no CloudKit call is made.

## Entry points

```swift
// Launch, on the Mac and the iPhone, only in a configured build:
if let container = CloudSyncConfiguration.containerIdentifier() {
    let services = try StudyServices.live(syncContainer: container)   // attaches the metadatabase
    let sync = CloudSync(services: services, container: container)   // non-nil here
    Task { await sync?.start() }
}
sync.status      // .idle, .starting, .running, .unavailable(reason), .failed(reason)
sync.isRunning   // the phone's agent sheet shows only while true
sync.stop()
```

`CloudSync(services:container:)` is nil without a container (the default argument reads
`CloudSyncConfiguration.containerIdentifier()`), so nothing about sync is reachable otherwise.

## Rules

- **The account first**: `start()` asks `CKContainer(identifier:).accountStatus()`; anything but
  available is `.unavailable` with a readable reason ("Not signed in to iCloud", "iCloud is
  restricted", "iCloud is unavailable", "iCloud status unknown"). `start()` again retries.
- **Tables** (`SyncedTables`): every table of `Schema.tableNames` except `job` (device-local
  processing state: each device runs its own jobs). The search index (`Schema.localTableNames`,
  `Schema.virtualTableNames`) is rebuilt per device and never syncs. The record types are listed
  twice (a checked list and the engine's parameter pack); a table of the schema missing from the
  list fails the start ("Sync doesn’t cover …") instead of leaving its rows on one device.
- **Blobs do not sync** in M7 (decks, audio, images are files in the BlobStore, not rows): a
  synced row whose blob is missing shows as not on this device (the phone's recorder shows a
  deck only when its blob is there).
- **Failures** are readable (`.failed(localizedDescription)`), logged under `sync`, and never
  crash; the library keeps working without sync.

## Requests for the integrator

1. Open the library with `StudyServices.live(syncContainer: CloudSyncConfiguration.containerIdentifier())`
   (nil today: unchanged) and start `CloudSync(services:)` at launch on both platforms when it is
   non-nil; pass `cloudSync?.isRunning ?? false` to the phone's agent relay.
2. A phone configured for sync does not seed the three courses (the Mac's come down).
3. Turning sync on (later, the user's): an "Apple Development" identity, the iCloud capability
   with a container (e.g. `iCloud.com.example.studyportal`) on the app (Mac and iOS),
   `StudyPortalCloudKitContainer` in the Info.plist of that build, automatic signing with
   `-allowProvisioningUpdates`. Then check SQLiteData's schema validation once on a copy of the
   library (it rejects tables that break its CloudKit rules, see docs/schema.md).
4. Not built (later, if wanted): re-checking on `CKAccountChanged`, a sync line in Settings.

## Design notes for the integrator

**decisions.md** rows to add:

| Date | Decision | Why |
|---|---|---|
| 2026-10-19 | Sync, when configured: the iCloud account is checked first (`.unavailable` with the reason otherwise), then SQLiteData's `SyncEngine` over `Schema.tableNames` except `job`; the search index never syncs; a schema table the sync list lacks fails the start | `job` is each device's own processing; derived tables are rebuilt; a forgotten table must not silently stay on one device |
| 2026-10-19 | Blobs (decks, audio, images) do not sync in M7; a row whose blob is missing shows as not on this device | CloudKit assets for 500 MB recordings and decks need their own design (CKAsset records or iCloud Drive), later |

**Strings** (DESIGN 9, only where the status is shown): "Not signed in to iCloud", "iCloud is
restricted", "iCloud is unavailable", "iCloud status unknown", "Sync doesn’t cover …".
