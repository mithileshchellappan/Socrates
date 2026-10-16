import Capture
import SwiftUI

/// Recording-clock times as the app shows them: `38:41`, `1:02:07`.
public enum ClockText {
    public static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// Small grey section heading used in the inspector ("Captions", "Notes", "Stamps").
struct SectionLabel<Accessory: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            accessory
        }
    }
}

extension SectionLabel where Accessory == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.title = title
        self.accessory = EmptyView()
    }
}

extension SectionLabel {
    init(_ title: LocalizedStringKey, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }
}

/// A recording-clock time chip in SF Mono.
struct TimeChip: View {
    let seconds: TimeInterval?
    var isCurrent = false

    var body: some View {
        Text(seconds.map(ClockText.string) ?? "--:--")
            .font(.system(size: 10.5, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

/// Input level as five bars.
struct LevelMeter: View {
    let level: Float
    var isActive = true

    private static let heights: [CGFloat] = [4, 7, 9, 11, 12]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Self.heights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(isLit(index) ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: Self.heights[index])
            }
        }
        .frame(height: 12, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func isLit(_ index: Int) -> Bool {
        isActive && level >= Float(index + 1) / Float(Self.heights.count + 1)
    }
}

/// Pulsing red dot shown while recording.
struct RecordingDot: View {
    var isPulsing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
        if isPulsing && !reduceMotion {
            dot.phaseAnimator([1.0, 0.35]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
        } else {
            dot
        }
    }
}
