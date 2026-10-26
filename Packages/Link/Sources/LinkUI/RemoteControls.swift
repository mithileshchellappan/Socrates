import Link
import RecorderContract
import SwiftUI

/// The panel's row of controls, as on the Live Activity: [⏸ / ▶︎] a 34 pt circle, [› Next Slide]
/// flexible, [■ Stop…]. Each is enabled exactly by `PhoneLink.canSend` and stays pressed while
/// its command is pending; what the buttons show comes from the phone's snapshot only (Resume
/// appears after a paused snapshot, never after the click).
struct RemoteControls: View {
    let link: PhoneLink
    let phase: RecorderSnapshot.Phase
    /// Stop… asks first; the panel owns the question.
    let confirmStop: () -> Void

    private var toggle: RemoteAction { phase == .paused ? .resume : .pause }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: sendToggle) {
                Image(systemName: toggle == .resume ? "play.fill" : "pause.fill")
                    .font(.system(size: 14))
                    .frame(width: 34)
            }
            .buttonStyle(RemoteButtonStyle(kind: toggle == .resume ? .resume : .quiet, isHeld: link.pending.contains(toggle)))
            .disabled(!link.canSend(toggle))
            .accessibilityLabel(toggle == .resume ? Text("Resume") : Text("Pause"))

            Button(action: sendNextSlide) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                    Text("Next Slide")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemoteButtonStyle(kind: .prominent, isHeld: link.pending.contains(.nextSlide)))
            .disabled(!link.canSend(.nextSlide))

            Button(action: confirmStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                    Text("Stop…")
                }
                .padding(.horizontal, 13)
            }
            .buttonStyle(RemoteButtonStyle(kind: .stop, isHeld: link.pending.contains(.stop)))
            .disabled(!link.canSend(.stop))
        }
    }

    private func sendToggle() {
        link.send(toggle)
    }

    private func sendNextSlide() {
        link.send(.nextSlide)
    }
}
