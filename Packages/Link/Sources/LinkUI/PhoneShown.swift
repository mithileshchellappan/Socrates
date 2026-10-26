import Link
import RecorderContract

/// What the Mac's surfaces show of the phone (DESIGN 8.11), read from `PhoneLink` in one place so
/// the menu bar label, the toolbar capsule, the panel and the Lecture menu never disagree.
@MainActor
struct PhoneShown {
    /// What the menu bar label and the capsule draw.
    enum Item {
        case recording(RemoteRecording)
        case arriving(stored: Int64, total: Int64)
    }

    /// The phone's recording while it records, pauses or stops; a stopped one only until its
    /// arrival takes its place.
    let recording: RemoteRecording?
    /// The recordings being copied to the Mac.
    let arrivals: [Arrival]
    /// The link's last snapshot, also of a recording that stopped (its course colour for the
    /// arrival's dot).
    private let last: RemoteRecording?

    init(_ link: PhoneLink) {
        last = link.recording
        arrivals = link.arrivals
        if let recording = link.recording, recording.snapshot.phase != .stopped || link.arrivals.isEmpty {
            self.recording = recording
        } else {
            recording = nil
        }
    }

    /// The recording the Lecture menu's items act on: one that has not stopped.
    var controllable: RemoteRecording? {
        guard let recording, recording.snapshot.phase != .stopped else { return nil }
        return recording
    }

    /// The label and the capsule: the recording while it records or pauses (also frozen), else
    /// the bytes arriving (all arrivals together), else the last state of a recording that
    /// stopped; nil when there is nothing to show.
    var item: Item? {
        if let recording, recording.snapshot.phase == .recording || recording.snapshot.phase == .paused {
            return .recording(recording)
        }
        if !arrivals.isEmpty {
            let stored = arrivals.reduce(Int64(0)) { $0 + $1.stored }
            let total = arrivals.reduce(Int64(0)) { $0 + $1.total }
            return .arriving(stored: stored, total: total)
        }
        return recording.map(Item.recording)
    }

    /// The course colour of an arriving recording, when the link's snapshot was of it.
    func colorHex(of arrival: Arrival) -> String? {
        guard let last, last.snapshot.recordingID == arrival.id else { return nil }
        return last.snapshot.course.colorHex
    }
}
