import Link
import StudyUI
import SwiftUI

/// The menu bar extra's window and the toolbar capsule's popover (mockup 62b, DESIGN 8.11), 300 pt
/// wide on the system's material (the window or popover draws it): the phone's recording (course
/// and session, the timer and slide, Pause or Resume, Next Slide and Stop…, which asks first, and
/// a remote problem), then a hairline and the recordings arriving, each with its progress. It
/// renders `PhoneLink` and sends its intents; it infers nothing.
public struct PhoneRecordingPanel: View {
    let link: PhoneLink

    public init(link: PhoneLink) {
        self.link = link
    }

    public var body: some View {
        let shown = PhoneShown(link)
        VStack(alignment: .leading, spacing: 0) {
            if let recording = shown.recording {
                RemoteRecordingView(link: link, recording: recording)
                if !shown.arrivals.isEmpty {
                    Hairline()
                        .padding(.horizontal, -14)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(shown.arrivals) { arrival in
                    ArrivalRow(arrival: arrival, colorHex: arrival.colorHex ?? shown.colorHex(of: arrival))
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}
