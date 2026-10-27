import SwiftUI

/// The mark before the phone's time: a red dot that pulses while the phone records and is
/// reachable (steady under Reduce Motion), a hollow secondary ring when frozen, nothing while
/// paused (the capsule shows `pause.fill` there itself).
struct RemoteDot: View {
    let mark: RemoteMark
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch mark {
        case .recording:
            let dot = Circle()
                .fill(.red)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
            if reduceMotion {
                dot
            } else {
                dot.phaseAnimator([1.0, 0.35]) { dot, opacity in
                    dot.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.8)
                }
            }
        case .frozen:
            Circle()
                .strokeBorder(.secondary, lineWidth: 1.5)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .paused:
            EmptyView()
        }
    }
}
