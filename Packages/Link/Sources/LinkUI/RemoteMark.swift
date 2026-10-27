import Link
import RecorderContract
import SwiftUI

/// How the Mac draws the phone's recording (DESIGN 8.11): recording and reachable, paused and
/// reachable, or frozen: the last state the phone sent, grey, its time standing still (the phone
/// is not reachable, or the recording no longer runs). Read from the link's snapshot and
/// freshness only; nothing is guessed.
enum RemoteMark: Hashable {
    case recording, paused, frozen

    init(_ recording: RemoteRecording) {
        guard recording.isLive else {
            self = .frozen
            return
        }
        switch recording.snapshot.phase {
        case .recording: self = .recording
        case .paused: self = .paused
        case .stopping, .stopped: self = .frozen
        }
    }

    /// What VoiceOver says for the menu bar label: "Recording" or "Paused" only while the phone
    /// confirms it; frozen, the device ("iPhone") with the last time and slide as its value.
    var accessibilityLabel: Text {
        switch self {
        case .recording: Text("Recording")
        case .paused: Text("Paused")
        case .frozen: Text("iPhone")
        }
    }

    /// The menu bar label's glyph: `circle.fill`, `pause.fill`, a hollow `circle`.
    var menuGlyph: String {
        switch self {
        case .recording: "circle.fill"
        case .paused: "pause.fill"
        case .frozen: "circle"
        }
    }
}
