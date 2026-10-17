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

/// Text styles of the live screen. On the Mac these are the mockup's sizes (02-live): 11 pt
/// section labels and their actions, a 12 pt filing line.
enum LiveFont {
    #if os(macOS)
    static let sectionLabel = Font.subheadline.weight(.semibold)
    static let sectionAction = Font.subheadline.weight(.medium)
    static let filingLine = Font.callout
    #else
    static let sectionLabel = Font.caption.weight(.semibold)
    static let sectionAction = Font.caption.weight(.medium)
    static let filingLine = Font.caption
    #endif
}

/// Small grey section heading used in the inspector ("Captions", "Notes", "Stamps").
struct SectionLabel<Accessory: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(LiveFont.sectionLabel)
                .tracking(0.22)
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
            .background(.accentSoft, in: Capsule())
    }
}

/// Input level as five bars of uneven height (a meter, not a signal-strength staircase).
struct LevelMeter: View {
    let level: Float
    var isActive = true

    private static let heights: [CGFloat] = [4, 7, 11, 8, 12]

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

/// The running recording: a pulsing red dot and the elapsed time in SF Mono. Shown in the live
/// toolbar, and in the main window's toolbar while the live screen is closed.
public struct RecordingIndicator: View {
    let session: LiveLectureSession

    public init(session: LiveLectureSession) {
        self.session = session
    }

    public var body: some View {
        HStack(spacing: 6) {
            RecordingDot(isPulsing: session.phase == .recording)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(ClockText.string(session.elapsed(at: timeline.date)))
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
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

/// The mockups' flag (02): a pole and a pennant with a notched tail, drawn in a 24-unit box like
/// their icons (`M5 21V4`, `M5 4h11l-2 4 2 4H5`). SF's flag is a wavy banner.
struct PennantShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        path.move(to: point(5, 21))
        path.addLine(to: point(5, 4))
        path.addLine(to: point(16, 4))
        path.addLine(to: point(14, 8))
        path.addLine(to: point(16, 12))
        path.addLine(to: point(5, 12))
        return path
    }
}
