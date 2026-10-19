import Capture
import SwiftUI

/// The last seconds of input as bars that end at the red playhead, with an accent line for
/// each slide stamp in view (mockup 09). It samples the input level four times a second while
/// recording with the screen on (nothing runs while the phone is locked); the history lives in
/// the view and starts again when the screen opens.
struct RecorderWaveform: View {
    let session: LiveLectureSession?
    let isPreview: Bool
    /// The scene is active (not locked, not in the background).
    let isActive: Bool

    @State private var levels: [Float] = []

    /// Seconds per bar, and the bar pitch (3 pt bar + 3 pt gap).
    static let interval: TimeInterval = 0.25
    static let pitch: CGFloat = 6
    static let barWidth: CGFloat = 3
    /// The newest bars kept (more than fit on any phone).
    static let capacity = 96

    var body: some View {
        let elapsed = session?.elapsed(at: Date()) ?? 0
        let stampTimes = (session?.stamps ?? [])
            .filter { $0.kind.showsSlide && $0.kind != .start }
            .compactMap { session?.time(of: $0) }
        // Read here, not only inside the Canvas: a new bar must redraw it (the preview's bars,
        // and the live ones while the session's own state stays the same).
        let bars = levels
        Canvas { context, size in
            draw(in: &context, size: size, levels: bars, elapsed: elapsed, stampTimes: stampTimes)
        }
        .accessibilityHidden(true)
        .task(id: Sampling(isOn: isSampling)) {
            guard isSampling else { return }
            while !Task.isCancelled {
                append(session?.level ?? 0)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onAppear {
            if isPreview, levels.isEmpty { levels = Self.previewLevels }
        }
    }

    private struct Sampling: Hashable { var isOn: Bool }

    private var isSampling: Bool {
        !isPreview && isActive && session?.isRecording == true
    }

    private func append(_ level: Float) {
        levels.append(level)
        if levels.count > Self.capacity { levels.removeFirst(levels.count - Self.capacity) }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, levels: [Float], elapsed: TimeInterval, stampTimes: [TimeInterval]) {
        // The playhead sits where 52 bars end on a 358 pt wide phone (312 pt), proportionally.
        let playhead = (size.width * 312 / 358).rounded()
        let baseline = size.height - 24

        var base = Path()
        base.move(to: CGPoint(x: 0, y: baseline))
        base.addLine(to: CGPoint(x: size.width, y: baseline))
        context.stroke(base, with: .style(.separator), lineWidth: 0.5)

        let visible = Int(playhead / Self.pitch)
        for (offset, level) in levels.suffix(visible).reversed().enumerated() {
            let height = 4 + CGFloat(min(max(level, 0), 1)) * 40
            let x = playhead - CGFloat(offset + 1) * Self.pitch
            let bar = CGRect(x: x, y: baseline - height / 2, width: Self.barWidth, height: height)
            context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .style(.secondary))
        }

        for time in stampTimes {
            let x = playhead - CGFloat((elapsed - time) / Self.interval) * Self.pitch
            guard x >= 0, x <= playhead else { continue }
            context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .style(.tint))
            context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: -3, width: 7, height: 7)), with: .style(.tint))
        }

        let top = size.height - 53
        context.fill(Path(roundedRect: CGRect(x: playhead - 1, y: top, width: 2, height: 56), cornerRadius: 1), with: .color(.red))
        context.fill(Path(ellipseIn: CGRect(x: playhead - 4, y: top - 4, width: 8, height: 8)), with: .color(.red))
    }

    /// Mockup 09's bars, for previews.
    static let previewLevels: [Float] = ([
        8, 14, 22, 30, 18, 10, 6, 4, 12, 26, 34, 28, 20, 24, 16, 8, 5, 4, 10, 20, 32, 40, 30, 22, 14, 18,
        26, 20, 12, 6, 4, 4, 8, 16, 28, 36, 32, 24, 12, 5, 14, 22, 30, 26, 34, 28, 18, 12, 20, 30, 38, 26,
    ] as [Double]).map { Float(($0 - 4) / 40) }
}
