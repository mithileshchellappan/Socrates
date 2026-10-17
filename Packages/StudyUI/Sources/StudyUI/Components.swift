import StudyCore
import SwiftUI

extension Color {
    /// `#rrggbb` (sRGB). Returns nil for anything else.
    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A course's colour, or the accent colour when its hex is unreadable.
    public static func course(_ course: Course?) -> Color {
        course.flatMap { Color(hex: $0.colorHex) } ?? .accentColor
    }

    /// The professor's voice (pins, quote bars, exam stars). Orange is reserved for it.
    public static let professor = Color.orange
}

/// Times on a recording clock as "m:ss" or "h:mm:ss" (shown in SF Mono).
public enum TimeText {
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A day as every screen writes it ("Wed, Oct 14" or "Mi., 14. Okt.", the locale's own order):
/// sidebar, Today, review, search, filing toasts and Course Settings share this skeleton.
public enum DayText {
    public static func day(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(style(locale: locale, timeZone: timeZone))
    }

    public static func style(locale: Locale = .current, timeZone: TimeZone = .current) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)
    }
}

/// The course colour dot used in lists, headers and the sidebar.
public struct CourseDot: View {
    private let color: Color
    private let size: CGFloat

    public init(hex: String, size: CGFloat = 8) {
        color = Color(hex: hex) ?? .accentColor
        self.size = size
    }

    public init(course: Course?, size: CGFloat = 8) {
        color = .course(course)
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The quiet jump-to-time affordance ("37:59"): SF Mono on a tinted capsule. Plays the recording
/// from that second (the action decides how).
public struct TimeChip: View {
    private let seconds: Double
    private let showsPlayGlyph: Bool
    private let action: () -> Void

    public init(_ seconds: Double, showsPlayGlyph: Bool = false, action: @escaping () -> Void) {
        self.seconds = seconds
        self.showsPlayGlyph = showsPlayGlyph
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if showsPlayGlyph {
                    Image(systemName: "play.fill")
                        .imageScale(.small)
                }
                Text(TimeText.clock(seconds))
                    .monospacedDigit()
            }
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Play from \(TimeText.clock(seconds))"))
    }
}

/// A slide reference ("S13"): grey capsule, opens the slide.
public struct SlideChip: View {
    private let page: Int
    private let action: () -> Void

    public init(page: Int, action: @escaping () -> Void) {
        self.page = page
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(verbatim: "S\(page)")
                .monospacedDigit()
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Slide \(page)"))
    }
}
