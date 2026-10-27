import Link
import SwiftUI

/// The main window's toolbar item while the phone's recording is known or arriving (mockup 62c;
/// the app puts it in its own glass group before Record or `RecordingIndicator`): `iphone`, the
/// mark, the time in SF Mono 12 (red while the phone records and is reachable, secondary paused
/// or frozen) and "S10"; arriving, `iphone` and "212 of 520 MB". A click opens
/// `PhoneRecordingPanel` in a popover, Stop… and its question included.
public struct PhoneRecordingCapsule: View {
    let link: PhoneLink

    @State private var showsPanel = false

    public init(link: PhoneLink) {
        self.link = link
    }

    public var body: some View {
        Button(action: togglePanel) {
            PhoneCapsuleLabel(item: link.item, now: link.now)
        }
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            PhoneRecordingPanel(link: link)
        }
        .accessibilityLabel(Text("iPhone"))
    }

    private func togglePanel() {
        showsPanel.toggle()
    }
}
