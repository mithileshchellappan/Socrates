import Link
import SwiftUI

/// The menu bar extra's window and the toolbar capsule's popover: the course and session, the timer
/// and slide, Pause or Resume, Next Slide and Stop… (which asks first), a remote problem, and the
/// arrivals with their progress.
public struct PhoneRecordingPanel: View {
    let link: PhoneLink

    public init(link: PhoneLink) {
        self.link = link
    }

    public var body: some View {
        EmptyView()
    }
}
