import Link
import SwiftUI

/// The Lecture menu's iPhone section (mockup 62d; `LiveLectureCommands`' trailing slot): a
/// divider, then "iPhone" with Pause Recording or Resume Recording (the Live Activity's words; the
/// phone's snapshot decides which) and Next Slide, only while a phone recording is known, each
/// enabled exactly by `PhoneLink.canSend`. No key equivalents: the plain keys and ⇧⌘R belong to the
/// live window and Review. Stop is not here: it asks first, so it lives in the panel.
public struct PhoneRecordingMenuItems: View {
    let link: PhoneLink

    public init(link: PhoneLink) {
        self.link = link
    }

    public var body: some View {
        if let recording = link.recording {
            Divider()
            Section("iPhone") {
                if recording.snapshot.phase == .paused {
                    Button("Resume Recording", action: resume)
                        .disabled(!link.canSend(.resume))
                } else {
                    Button("Pause Recording", action: pause)
                        .disabled(!link.canSend(.pause))
                }
                Button("Next Slide", action: nextSlide)
                    .disabled(!link.canSend(.nextSlide))
            }
        }
    }

    private func pause() {
        link.send(.pause)
    }

    private func resume() {
        link.send(.resume)
    }

    private func nextSlide() {
        link.send(.nextSlide)
    }
}
