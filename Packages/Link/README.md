# Link

The recording link between the student's iPhone and Mac (docs/decisions.md, 2026-10-26):

- **Recordings reach the Mac by themselves.** While the iPhone records, its closed audio segments
  go to the Mac; at Stop the rest follows, and the Mac files the recording with the usual toast.
  Share stays on every outbox row.
- **The Mac remote.** While the iPhone records, the Mac shows the recording (time, slide, course)
  in a menu bar extra, the main window's toolbar and the Lecture menu, and controls it: Pause,
  Resume, Next Slide, Stop… (asks first).

One direct connection carries both: Bonjour (`_socrates._tcp`) over Wi-Fi, Ethernet and the USB
cable, and peer-to-peer Wi-Fi during classes that record; TCP with TLS 1.3, both sides' keys
pinned. Trust comes from the student's own `link_device` rows in the synced library, so the link
exists only in the iCloud build; ad-hoc and public builds have no link and nothing changes there.

| Product | Contents | Imports |
|---|---|---|
| `LinkCore` | Values and pure rules, no I/O: `LinkProtocol` (ALPN `socrates-link/1`, the service type), `LinkCapability` (`control.1`, `files.1`), `LinkDeviceID`, `LinkRole`, `LinkFingerprint`, the messages (`Hello`, `Goodbye`, `Ping`, `SnapshotMessage`, `Holdings`, `Offer` + `OfferedFile`, `Want`, `Chunk`, `Stored`, `Received`), `LinkMessage`, `LinkFrame` + `LinkProtocolError`, `LinkPolicy`, `InboxRules`, `PeerToPeerWindow`, `SelfSignedCertificate` | Foundation, CryptoKit, RecorderContract |
| `Link` | Everything with I/O, behind two `@MainActor @Observable` models: `PhoneLink` (the Mac) with `RemoteRecording`, `Arrival`, `RemoteProblem`, `RemoteAction`; `MacLink` (the iPhone) with `CaptureDelivery`. Internal: the channel, the identity store, the device directory, the Mac's service and inbox, the phone's agent and outbox | LinkCore, RecorderContract, StudyCore, Capture, GRDB, Network, Security |
| `LinkUI` | SwiftUI only: `PhoneRecordingMenuLabel`, `PhoneRecordingPanel`, `PhoneRecordingCapsule`, `PhoneRecordingMenuItems` (the Mac), `CaptureDeliveryLabel` (the phone's outbox row) | Link, RecorderContract, StudyUI, CaptureUI |

Dependencies point one way: Link uses the Recorder package's contract only, and the Recorder
package never depends on Link (SwiftPM refuses a cycle). The phone's outbox shows the link's
state through `RecorderScreen`'s delivery slot, which the app fills with `CaptureDeliveryLabel`.

## Entry points

```swift
// The Mac (AppModel), only when cloudSync != nil:
let phoneLink = PhoneLink.mac(services: services) { url in await filingCenter.file([url]) }
phoneLink.start()          // after cloudSync.start(), unless cloudSync.accountSwitched
phoneLink.stop()           // when cloudSync.accountSwitched turns true (nothing at quit)
phoneLink.showsItem        // MenuBarExtra(isInserted:), the toolbar capsule
phoneLink.item             // what the label and the capsule draw: .recording(_) or .arriving(stored:total:)
phoneLink.recording        // RemoteRecording?: snapshot, freshness (.live / .lastSeen), elapsed(at:)
phoneLink.arrivals         // [Arrival]: title, course colour, stored of total bytes
phoneLink.canSend(.pause)  // live, control on, the snapshot accepts it, nothing pending
phoneLink.send(.nextSlide)

// The iPhone (AppModel), only when cloudSync != nil:
let macLink = MacLink.phone(services: services, recorder: phoneRecorder, beginBackgroundTime: BackgroundTime.begin)
macLink.start()
macLink.setActive(scenePhase == .active)
RecorderScreen(recorder: recorder) { id in CaptureDeliveryLabel(delivery: macLink.delivery(of: id)) }
```

DEBUG: `PhoneLink.preview(recording:arrivals:problem:pending:now:)` and `MacLink.preview(deliveries:)` for
parity renders; they never connect.

## Inside `Link`

Each model owns its actor and every task it starts; the actors own their listeners, browsers,
dials, sessions and timers, and cancel them in `stop()`.

| Type | Owns |
|---|---|
| `PhoneLink` (Mac, main actor) | `MacLinkService`; stores what its events (`MacLinkEvent`) say of the recording and the arrivals, the pending buttons (held until the result and the snapshot that shows it), the remote problem, the second tick |
| `MacLinkService` (actor) | the infrastructure and peer-to-peer listeners, admission, one `MacSession` per phone, the commands waiting for results, the filing queue, App Nap's activity; the one owner of the recording shown (newest snapshot, frozen at the last byte heard, gone when stopped, filed another way or after the frozen lifetime) and of the arrival rows (each ends with its phone's session) |
| `MacSession` | one phone's messages in order: snapshots and results to the service, holdings, offers and chunks to the inbox, one want at a time, filing then `received`; a recording that cannot be completed waits for the next session without holding up the others |
| `RecordingInbox` (actor) | `Incoming/<device>/<uuid>.lecture.partial/`: `.part` files, their hashes, syncs and acknowledgements, the package checks and the move into `Recordings/` |
| `MacLink` (iPhone, main actor) | `PhoneLinkAgent`; bridges the recorder's snapshots to it, shows its deliveries; begins background time the moment the recorder shows a Stop |
| `LinkBackgroundTime` (main actor) | the one UIKit background task: begun before any Stop runs (by `MacLink`, by the agent before the Mac's Stop), ended by the agent or by iOS |
| `PhoneLinkAgent` (actor) | when to link, browsing and dialing, the session with the Mac, what the Mac has been told (`sync`, a pass of its own), commands to the recorder, receipts, when background time ends |
| `Outbox`, `OutboxReceipts` | the outbox as the link sees it (what may be offered, hashes, bytes) and `PhoneCaptures/.link/<uuid>.json` |
| `LinkChannel` / `DirectChannel` (actor) | the transport seam and its TCP + TLS route: framing, hello and its checks, the two lanes, pings and loss |
| `LinkIdentityStore`, `LinkIdentity`, `PeerCertificate` | the Keychain key, the certificate made from it, the peer's key fingerprint and ALPN |
| `LinkDirectory` (actor), `TrustedPeers` | this device's `link_device` row and the trusted rows of the other platform, followed as they sync |

What the phone may offer (`Outbox`): the recording going on offers its audio segments up to the
snapshot's `closedSegments`, never its JSON files; any other capture offers all its audio, and
its JSON files once it is final (it ended, or its last event is not a pause); a capture without
an end whose files changed in the last minute is left out until the recorder says what it is
(the agent lists again when that minute is over), and one with a segment file it cannot read is
left out rather than offered without it. The holdings name every capture still on the phone
without the Mac's answer, offered or not; an outbox that cannot be read sends none. The phone
keeps one persistent fact per capture, its receipt, written only for a recording offered on that
session; what the Mac holds is its staging folder. Neither keeps anything else.

## Protocol (generation 1)

- **Frames**: `[kind UInt8][length UInt32 big-endian][body]`. The header is read first and the
  length checked against `LinkFrame.maximumBody` (256 KiB + 16) before any body byte is read.
  JSON bodies with the default encoder and decoder; a chunk's body is binary (want, offset, bytes).
  A kind this build does not know is read and skipped; kinds are never reused.
- **Messages** (`LinkMessage`): 1 hello, 2 goodbye, 3 ping, 4 pong; 16 snapshot, 17 command,
  18 result; 32 holdings, 33 offer, 34 want, 35 chunk, 36 stored, 37 received.
- **Features** come from the hellos' capabilities, never from app versions: `control.1` is on
  only when both list it and their `RecorderContractVersion` is equal; `files.1` is independent.
- **Commands** are `RecorderCommand`s with origin `remote` and a fresh id, Pause and Resume with
  the snapshot's sequence as `basis`, Next Slide with the slide shown. The phone applies an id
  once; the link never resends; a lost connection clears what was pending.
- **Snapshots** carry the elapsed time computed on the phone at sending; the Mac counts on from
  receipt with its own clock. The two devices' clocks are never compared.
- **Files**: the phone offers a recording's closed segments as they close and every file once it
  is final; the Mac asks for one file at a time from the length it holds, acknowledges durable
  bytes (`stored`), checks each file's SHA-256 and that every segment the manifest lists came,
  moves the whole package into `Recordings/` (the move synced), files it, then says `received`.
  A package found in `Recordings/` that nothing filed is filed when the phone offers it again. The phone keeps one receipt per capture and never offers it again.
  An offer names its manifest's course (`courseID`, optional): the arrival row's dot takes the
  Mac's own colour for it.

## Rules

- **Trust**: the peer's TLS leaf key, hashed (`LinkFingerprint`), must equal the hash of an
  unretired `link_device` row of the other platform, and its hello must name a row with that key
  (a reinstalled phone may stand in two until it sees its earlier row). The chain is never
  evaluated; a stored fingerprint is never trusted.
- **Keys**: one P-256 key per install in the data-protection Keychain (this device only, after
  first unlock, never synced, never through `KeychainSecretStore`), made only when the Keychain
  answers "not found"; any other answer leaves the link off for that launch.
- **Peer-to-peer** (the Mac): a second listener with its own random name, open only while
  `PeerToPeerWindow.isOpen` (a class that records is on, a phone recording is known, or a session
  runs on it). The phone always browses and dials with peer-to-peer included, and only while it
  records, has undelivered captures in the foreground, or holds background time after Stop.
- **Nothing personal is broadcast**: a random service name per launch, no TXT record, the
  certificate's name is "Socrates".

## Credits

The design learned from sill (github.com/Saffsanity/sill, Apache-2.0): pinned mutual TLS 1.3,
caps checked before reading, liveness and reconnect constants, limits before a peer is known.
No sill code is copied, not even small pieces; every line here is written for Socrates.
