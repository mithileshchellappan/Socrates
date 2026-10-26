import Link
import SwiftUI

/// The Lecture menu's "iPhone" section: Pause or Resume Recording and Next Slide, enabled exactly
/// by `PhoneLink.canSend`. Stop is not here: it asks first, so it lives in the panel.
public struct PhoneRecordingMenuItems: View {
    let link: PhoneLink

    public init(link: PhoneLink) {
        self.link = link
    }

    public var body: some View {
        EmptyView()
    }
}
