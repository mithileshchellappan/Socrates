# Sync

iCloud sync of the library (M7): `CloudSync`, SQLiteData's `SyncEngine` over the library tables,
behind `CloudSyncConfiguration` (StudyCore). It exists only in a build signed with the iCloud
entitlement that names its container in the Info.plist (`SocratesCloudKitContainer`), and only
for the real library. Both come from one build setting, `SOCRATES_ICLOUD = YES` (in a machine's
ignored `Config/Local.xcconfig`; `Config/Signing.xcconfig` defaults to NO): the container
`iCloud.$(BUNDLE_ID_PREFIX).socrates`, the Info.plist key (empty in simulator builds) and the
iCloud entitlements files (`App/macOS/Socrates-iCloud.entitlements`,
`App/iOS/Socrates-iCloud.entitlements`), so the key never ships without the entitlement (with the
key and no entitlement `CKContainer(identifier:)` traps). A build without it compiles sync but
never runs it, and makes no CloudKit call.

## Entry points

```swift
// Launch, on the Mac and the iPhone:
let services = try StudyServices.live(syncContainer: CloudSyncConfiguration.containerIdentifier())
// services.syncContainer: the container for the real library of a configured build, else nil
// (a SOCRATES_DATA_ROOT library never syncs); the metadatabase is attached when set.
let sync = CloudSync(services: services)   // nil without services.syncContainer; builds the engine
Task { await sync?.start() }               // ~2 s after launch (AppModel.startBackgroundWork)
await sync.retry()   // the Mac's wake, the app in front; also on CKAccountChanged (CloudSync itself)
sync.status          // .idle, .starting, .running, .unavailable(reason), .failed(reason)
sync.isRunning       // the phone's agent sheet shows only while true
sync.isSynchronizing // sending or fetching right now
sync.unsentCount     // rows iCloud has not received (refreshUnsent()); Settings ▸ Accounts
sync.accountSwitched // iCloud switched to another account in this run (the recording link stops)
sync.stop()
// Mac, before sync.start() (only once sync.hasEngine): rows the first upload deleted, once.
await LibraryRestore(services: services).runOnce { courseID in /* CourseSchedule.replan, counted */ }
// Mac: the daily backup (an actor).
let backup = LibraryBackup(services: services)
await backup.runHourly()   // now, then once an hour; runDaily() after each wake
```

## Rules

- **The engine is built at launch, before anything writes** (`CloudSync.init`, not started, no
  CloudKit call): SQLiteData's change triggers are temporary, per connection, and note only
  writes made after they exist. The app makes `CloudSync` first in `AppModel.init`.
- **The account first**: `start()` asks `CKContainer(identifier:).accountStatus()`; anything but
  available is `.unavailable` with a readable reason ("Not signed in to iCloud", "iCloud is
  restricted", "iCloud is unavailable", "iCloud status unknown").
- **Sync that is off starts again within the run** (`retry()`): when iCloud reports an account
  change (`CKAccountChanged`, which `CloudSync` follows for the app's life), when the Mac wakes and
  when the app comes to the front (the app's calls). Only from `.unavailable` or `.failed`, and
  never after a switch to another account in this run (`accountSwitched`; the next launch asks
  again). A sign-out and a sign-in to the same account resume where sync stopped.
- **A sign-out or an account switch keeps every row** (`AccountChangeGuard`, SQLiteData's
  `SyncEngineDelegate`): sync stops ("Not signed in to iCloud", "Another iCloud account").
  SQLiteData's default would delete every row of the synced tables on the device.
- **The first sync is additive.** Deletes reach iCloud only from the DELETE triggers of the device
  that deleted, so a phone that starts empty never deletes the Mac's rows; each device's first
  start marks its own rows for upload, then fetches. Conflicts are settled per field, the later
  edit wins.
- **The Mac's first upload is batched and resumable.** CKSyncEngine sends in batches; its pending
  list lives in its serialized state, which a quit or a crash can lose, so every later start
  queues again the rows iCloud has not received (`SyncedTables.queueUnsent`: metadata without a
  server record) and rows no engine noted (`queueUntracked`: rows without metadata, e.g. written
  by a build without sync). Settings ▸ Accounts' iCloud row shows "12,480 to upload" until it is
  "Up to date".
- **One copy before the first sync** (Mac): `VACUUM INTO Database/Socrates-before-sync.sqlite`
  (`AppPaths.preSyncBackup`), kept and never overwritten. A zone deleted on the server (CloudKit
  Console's Reset Development Environment, Delete Data in iCloud settings) deletes synced rows on
  every device, and SQLiteData has no hook to refuse it.
- **A new synced library on the iPhone** (`Database/Socrates-synced.sqlite`) drops the semester
  the migrations seeded (fixed id) before its first sync, so it can never overwrite the Mac's.
- **No parent references** (2026-10-22): every table goes to SQLiteData as a private table (`privateTables:`; the app never shares records). A shareable table's record takes its single foreign key as `CKRecord.parent`; iCloud refuses it while the parent is not on the server, and SQLiteData then deletes the row on the device when the key is ON DELETE CASCADE (a deck's pages went so in the Mac's first upload; `DeckPageRepair` in Capture puts them back from the PDF).
- **Rows the first upload deleted come back once** (Mac, `LibraryRestore`): before parent
  references were dropped, SQLiteData deleted some rows of one-foreign-key tables on the device
  when iCloud refused them, and ON DELETE CASCADE / SET NULL followed. On the first launch with
  sync (`LibraryRestore.runOnce(replan:)`, key `Socrates.restoredRowsLostToFirstSync`, before
  `start()`, only once `CloudSync.hasEngine`), weekly slots, generated future sessions, slide ink
  and mail attachments missing from the library are inserted again from
  `Socrates-before-sync.sqlite` (read-only), and sessions get their restored slot's link back; a
  row comes back only when its parent exists and no live row replaced it (a session within a
  minute, ink on the page, the attachment's part). Slots, their sessions and links come back only
  for a course with no live slot and no slot change the agent logged after the copy was made
  (undone or not), and a slot only when no `slot_remove` change names it: an old slot beside
  re-entered class times would double every class. Restored sessions start without a calendar
  event (the mirror adopts the one with their link or writes one), attachments without a file
  (fetched again on open). The library is copied first to `Socrates-before-restore.sqlite`
  (`AppPaths.preRestoreBackup`, kept). One transaction through the syncing writer, so every row is
  queued for upload; changed courses are replanned through the app's `replan` closure (Course
  Settings' `CourseSchedule.replan`; Sync does not depend on Courses), kept in
  `Socrates.replanAfterRestore` until each replan succeeds. A library
  without that copy, or whose copy was made after parent references were dropped
  (`LibraryRestore.parentReferencesDroppedAt`, by the file's date), sets the key and never
  restores. Logs only, category `sync.restore` (also the replans).
- **One backup a day** (Mac, the actor `LibraryBackup`: `runHourly()` at launch in the background
  and once an hour, `runDaily()` after each wake; calls at once run one after another):
  `Database/Backups/Socrates-<yyyy-MM-dd>.sqlite` (`AppPaths.backups`) through SQLite's backup
  API from a reader snapshot (the writer never waits), written as `.partial` and renamed, rollback
  journal mode, main schema only; kept: the newest 7 and the newest of each of the 4 latest weeks
  and 3 latest months (at most 14), so a loss noticed weeks later still has a copy from before it;
  files are matched by their day whatever the name before it (a renamed library keeps pruning its
  older copies); skipped when free disk is under twice the library plus 2 GB.
  After each new backup, a synced table with fewer rows than in the previous backup gets one
  `sync.backup` log line. The copy itself (`LibraryCopy`) is shared with the restore's.
- **Deletes made by sync are logged** (`SyncDeletionLog`, a GRDB transaction observer on the
  library's writer, added with the engine): deletes on synced tables while
  `SyncEngine.isSynchronizing` (another device's deletes, deleted or reset zones, and their
  cascades) give one `sync.deletes` line per transaction with table names and counts. Read them with
  `log show --last 7d --info --predicate 'subsystem == "<bundle ID>" AND category BEGINSWITH "sync."'`.
- **Tables** (`SyncedTables`): every table of `Schema.tableNames` except `job` (device-local
  processing state) and the Mac-only `document` / `document_page`. The search index
  (`Schema.localTableNames`, `Schema.virtualTableNames`) is rebuilt per device and never syncs. The
  record types are listed twice (a checked list and the engine's parameter pack); a table of the
  schema missing from the list fails the start ("Sync doesn’t cover …") instead of leaving its rows
  on one device.
- **Blobs do not sync** in M7 (decks, audio, images are files in the BlobStore, not rows): a
  synced row whose blob is missing shows as not on this device. Rows over CloudKit's 1 MB record
  size stay on their device ("3 not uploaded").
- **Failures** are readable (`.failed(localizedDescription)`), logged under `sync`, and never
  crash; the library keeps working without sync.
- **One writer per library**: the triggers live in the syncing app's own connections, so another
  process writing the library (an older copy of the app) makes changes that never sync. Keep one
  copy of the Mac app.

## Turning it on (a machine's `Config/Local.xcconfig`)

```
SOCRATES_TEAM = <team ID>
BUNDLE_ID_PREFIX = <your reverse-DNS prefix>
SOCRATES_MAC_SIGN_IDENTITY = Apple Development
SOCRATES_MAC_SIGN_STYLE = Automatic
SOCRATES_ICLOUD = YES
```

Build both apps once with `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`: Xcode
registers the App ID `<prefix>.socrates` (and `.widgets`), the container
`iCloud.<prefix>.socrates`, Push Notifications, and makes the development profiles. Both devices
use CloudKit's Development environment (just-in-time schema: a migration that adds a table or a
column needs no CloudKit Console deploy).
