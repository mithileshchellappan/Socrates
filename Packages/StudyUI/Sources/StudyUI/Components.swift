import StudyCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Color {
    /// A course colour from `#rrggbb` (sRGB): the hex itself in light appearance, a brighter
    /// variant in dark (`CourseColor.dark`, mockups: #0a84ff → #409cff). Nil for anything else.
    public init?(hex: String) {
        guard let light = CourseColor.rgb(hex: hex) else { return nil }
        self.init(light: light, dark: CourseColor.dark(light))
    }

    /// One sRGB colour in light appearance, another in dark.
    init(light: CourseColor.RGB, dark: CourseColor.RGB) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #else
        self.init(.sRGB, red: light.red, green: light.green, blue: light.blue)
        #endif
    }

    /// A course's colour, or the accent colour when its hex is unreadable.
    public static func course(_ course: Course?) -> Color {
        course.flatMap { Color(hex: $0.colorHex) } ?? .accentColor
    }

    /// The professor's voice (pins, quote bars, exam stars). Orange is reserved for it: the
    /// mockups' deep amber (#f08a00, #ff9f0a dark), not the lighter system orange.
    public static let professor = Color(light: CourseColor.RGB(0xf08a00), dark: CourseColor.RGB(0xff9f0a))

    /// The AI mark: the sparkle before AI text and on "Suggested" (the text itself stays
    /// secondary), and AI pins. Purple is reserved for it (the mockups' #8a56d1, #bf8cff dark).
    public static let ai = Color(light: CourseColor.RGB(0x8a56d1), dark: CourseColor.RGB(0xbf8cff))

    /// The accent at 12 % (light) or 24 % (dark), as the mockups' accent-soft: time chips.
    static func accentSoft(_ colorScheme: ColorScheme) -> Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.12)
    }
}

/// Course colours as sRGB components, and their dark-appearance variants.
enum CourseColor {
    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(_ value: UInt32) {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }

        /// "#409cff".
        var hex: String {
            func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
        }
    }

    /// `#rrggbb` or `rrggbb`; nil for anything else.
    static func rgb(hex: String) -> RGB? {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        return RGB(value)
    }

    /// The mockups' dark course colours for the default palette's first three.
    private static let darkPalette: [UInt32: UInt32] = [
        0x0a84ff: 0x409cff,
        0x2fae55: 0x3fd06b,
        0xe0457b: 0xff6b9a
    ]

    /// The colour in dark appearance: the mockups' value for a palette colour, else the same hue
    /// brighter and slightly less saturated (what the mockups do to the palette).
    static func dark(_ light: RGB) -> RGB {
        let key = UInt32((light.red * 255).rounded()) << 16 | UInt32((light.green * 255).rounded()) << 8 | UInt32((light.blue * 255).rounded())
        if let dark = darkPalette[key] { return RGB(dark) }
        var (hue, saturation, brightness) = hsb(light)
        saturation *= 0.86
        brightness = min(1, brightness + 0.14)
        return rgb(hue: hue, saturation: saturation, brightness: brightness)
    }

    private static func hsb(_ color: RGB) -> (Double, Double, Double) {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let delta = high - low
        var hue = 0.0
        if delta > 0 {
            if high == color.red {
                hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if high == color.green {
                hue = (color.blue - color.red) / delta + 2
            } else {
                hue = (color.red - color.green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, high == 0 ? 0 : delta / high, high)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGB {
        let sector = hue * 6
        let chroma = brightness * saturation
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) % 6 {
        case 0: (chroma, second, 0)
        case 1: (second, chroma, 0)
        case 2: (0, chroma, second)
        case 3: (0, second, chroma)
        case 4: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        let base = brightness - chroma
        return RGB(red: red + base, green: green + base, blue: blue + base)
    }
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

/// A day as every screen writes it: weekday, day, month, in that order and without commas ("Mon
/// 12 Oct", German "Mo. 12 Okt."), the order of the toolbar's "Friday, 16 October 2026" whatever
/// the region. Sidebar, Today, review, search, filing toasts and Course Settings use this pattern
/// (`SessionText.day` in Courses writes the same).
public enum DayText {
    public static func day(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(style(locale: locale, timeZone: timeZone))
    }

    public static func style(locale: Locale = .current, timeZone: TimeZone = .current) -> Date.VerbatimFormatStyle {
        Date.VerbatimFormatStyle(
            format: "\(weekday: .abbreviated) \(day: .defaultDigits) \(month: .abbreviated)",
            locale: locale,
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
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
    private let prefix: String?
    private let showsPlayGlyph: Bool
    private let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// `prefix` names the lecture when the chip is away from it ("L2" → "L2 · 0:37": mail,
    /// Today, Course Settings).
    public init(_ seconds: Double, prefix: String? = nil, showsPlayGlyph: Bool = false, action: @escaping () -> Void) {
        self.seconds = seconds
        self.prefix = prefix
        self.showsPlayGlyph = showsPlayGlyph
        self.action = action
    }

    /// "L2 · 0:37", or "0:37" without a prefix.
    public var label: String {
        guard let prefix, !prefix.isEmpty else { return TimeText.clock(seconds) }
        return "\(prefix) · \(TimeText.clock(seconds))"
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if showsPlayGlyph {
                    Image(systemName: "play.fill")
                        .imageScale(.small)
                }
                Text(verbatim: label)
                    .monospacedDigit()
            }
            .font(.chip)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(.tint)
            .background(Color.accentSoft(colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Play from \(TimeText.clock(seconds))"))
    }
}

extension Font {
    /// Time and slide chips: SF Mono at the mockups' 10.5 pt on the Mac.
    static var chip: Font {
        #if os(macOS)
        .system(size: 10.5, design: .monospaced)
        #else
        .system(.caption2, design: .monospaced)
        #endif
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
                .font(.chip)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Slide \(page)"))
    }
}
