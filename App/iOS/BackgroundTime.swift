import UIKit

/// link: UIKit's background time for the recording link (`MacLink.BeginBackgroundTime`). After Stop
/// iOS may suspend the app once the audio session ends; the link asks for time to send the rest of
/// the recording to the Mac. `expired` runs when iOS takes the time back (the link then ends it);
/// the returned call ends it early. Without time to give, nothing ends and nothing expires: what
/// is left goes the next time the app opens.
enum BackgroundTime {
    static func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> @MainActor @Sendable () -> Void {
        let application = UIApplication.shared
        let identifier = application.beginBackgroundTask(withName: name) {
            expired()
        }
        guard identifier != .invalid else { return {} }
        return { application.endBackgroundTask(identifier) }
    }
}
