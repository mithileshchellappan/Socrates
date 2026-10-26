import Link
import SwiftUI

/// The menu bar extra's label: the phone's recording as "● 38:22 S10" (paused, frozen and arriving
/// each drawn their own way, DESIGN 8.11).
public struct PhoneRecordingMenuLabel: View {
    let link: PhoneLink

    public init(link: PhoneLink) {
        self.link = link
    }

    public var body: some View {
        EmptyView()
    }
}
