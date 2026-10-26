import Foundation

/// When the Mac also listens over peer-to-peer Wi-Fi (AWDL), which takes its radio off channel
/// now and then and so is opened only when it can matter: the Mac and the phone in a lecture hall
/// whose Wi-Fi keeps devices apart.
public enum PeerToPeerWindow {
    /// Open while any of these holds:
    /// - a class of a course that records (`classes`) is on, `margin` seconds before and after
    ///   included: the Mac cannot learn of a recording over a link that does not exist yet;
    /// - a phone recording is known (`recordingKnown`: last seen running or paused, within the
    ///   frozen lifetime), so the link survives the student leaving a shared network;
    /// - a session is live on the peer-to-peer listener: the window never closes under it.
    public static func isOpen(
        now: Date, classes: [DateInterval], recordingKnown: Bool, peerToPeerSessions: Int, margin: TimeInterval
    ) -> Bool {
        if peerToPeerSessions > 0 || recordingKnown { return true }
        return classes.contains { interval in
            interval.start.addingTimeInterval(-margin) <= now && now <= interval.end.addingTimeInterval(margin)
        }
    }
}
