import Link
import SwiftUI

/// The main window's toolbar item while the phone's recording is known or arriving; a click opens
/// `PhoneRecordingPanel` in a popover.
public struct PhoneRecordingCapsule: View {
    let link: PhoneLink

    public init(link: PhoneLink) {
        self.link = link
    }

    public var body: some View {
        EmptyView()
    }
}
