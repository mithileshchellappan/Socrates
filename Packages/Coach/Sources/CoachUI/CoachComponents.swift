import StudyCore
import StudyUI
import SwiftUI

// Pieces the coach's screens share, and the hero card Today shares with them (moved here from
// CoursesUI's TodayView; StudyUI is their home once the integrator promotes them, README).

// MARK: - Hero card

/// The one emphasized card of a screen (mockups 01, 11–14, 19): the canvas card surface, radius
/// 14, a 0.5 pt separator ring. On the iPhone (mockup 16 `.hero`): padding 16/16/14, radius 22,
/// 4 pt between its lines.
public struct HeroCard<Content: View>: View {
    private let spacing: CGFloat
    private let top: CGFloat
    private let bottom: CGFloat
    private let content: Content
    @PhoneLayout private var isPhone

    public init(spacing: CGFloat = 3, top: CGFloat = 20, bottom: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.top = top
        self.bottom = bottom
        self.content = content()
    }

    public var body: some View {
        let radius: CGFloat = isPhone ? 22 : 14
        VStack(alignment: .leading, spacing: isPhone ? 4 : spacing) {
            content
        }
        .padding(.top, isPhone ? 16 : top)
        .padding(.bottom, isPhone ? 14 : bottom)
        .padding(.horizontal, isPhone ? 16 : 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }
}

// MARK: - The iPhone

/// Whether a screen is laid out for the iPhone (M7, mockup 16): a compact width on iOS. Always
/// false on the Mac, whose layouts stay as they are.
@propertyWrapper
public struct PhoneLayout: DynamicProperty {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init() {}

    public var wrappedValue: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
}

/// The one filled button on the iPhone (mockup 16 `.go`, `.next`): the whole width under the
/// thumb, a capsule, 17 pt semibold, the glyph before the title (or after it: Next's chevron).
public struct PhoneHeroButton: View {
    private let title: String
    private let systemImage: String?
    private let trailingImage: String?
    private let action: () -> Void

    public init(title: String, systemImage: String? = nil, trailingImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.trailingImage = trailingImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                if let trailingImage {
                    Image(systemName: trailingImage)
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

/// The hero's button title (mockup `.btn.lg`): a 13 pt medium title after a small glyph.
public struct HeroButtonLabel: View {
    private let title: String
    private let systemImage: String?

    public init(title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        Group {
            if let systemImage {
                Label {
                    Text(title)
                        .fontWeight(.medium)
                } icon: {
                    // The mockup's small play triangle (about 7 pt tall).
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .bold))
                }
            } else {
                Text(title)
                    .fontWeight(.medium)
            }
        }
        .padding(.vertical, 2)
    }
}

extension View {
    /// The one filled button (`.btn.primary.lg`): accent, 32 pt tall, radius 9.
    public func heroButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 9))
            .controlSize(.large)
    }

    /// A plain large button beside it (`.btn.lg`: Retake, Cancel, Count as wrong).
    func heroSecondaryButtonStyle() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 9))
            .controlSize(.large)
    }
}

// MARK: - Fills, meters, dots

/// The mockups' Fill 2 (`--fill2`: rgb(120,120,128) at 17 % light, 30 % dark): the empty mastery
/// dot, a meter's track, an answered number in the exam bar, a diagram's base box. ChatUI keeps
/// its own internal copy; StudyUI is its home once promoted (README).
struct Fill2: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255)
            .opacity(environment.colorScheme == .dark ? 0.30 : 0.17)
            .resolve(in: environment)
    }
}

/// A 4 pt meter (mockups 13–14): the track in Fill 2, the share in `color`.
struct Meter: View {
    let value: Double
    var color: Color

    var body: some View {
        Canvas { context, size in
            let radius = size.height / 2
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius), with: .style(Fill2()))
            let width = size.width * min(1, max(0, value))
            guard width > 0 else { return }
            let bar = CGRect(x: 0, y: 0, width: max(width, size.height), height: size.height)
            context.fill(Path(roundedRect: bar, cornerRadius: radius), with: .color(color))
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A topic's mastery as four 6 pt dots (mockups 13–15): filled in secondary, empty in Fill 2; the
/// help says the level and when it comes back ("Mastery 1 of 4 · again Thu 22 Oct").
public struct MasteryDots: View {
    private let mastery: TopicMastery
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    public init(_ mastery: TopicMastery) {
        self.mastery = mastery
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<CoachRules.maximumLevel, id: \.self) { index in
                Circle()
                    .fill(index < mastery.level ? AnyShapeStyle(.secondary) : AnyShapeStyle(Fill2()))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 33, alignment: .trailing)
        .contentShape(Rectangle())
        .help(CoachText.mastery(mastery, locale: locale, timeZone: timeZone))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(CoachText.mastery(mastery, locale: locale, timeZone: timeZone)))
    }
}

/// The 1–4 key of a choice (mockup `.kbd`): SF Mono 11 in a hairline key cap.
struct KeyCap: View {
    let number: Int
    var filled = false

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.mono(11))
            .monospacedDigit()
            .frame(minWidth: 18, minHeight: 17)
            .padding(.horizontal, 1)
            .foregroundStyle(filled ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
            .background(filled ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
                    .opacity(filled ? 0 : 1)
            }
            .accessibilityHidden(true)
    }
}

/// One AI block (DESIGN §5.1): one sparkle, then grey 12.5 pt text; `lead` (the verdict, "Right.")
/// in semibold.
struct AIBlock: View {
    let text: String
    var lead: String?
    /// 12.5 pt on the Mac; 13 on the iPhone (mockup 16 `.qai`).
    var size: CGFloat = 12.5

    var body: some View {
        Text("\(Text(Image(systemName: "sparkle")).foregroundStyle(Color.ai).font(.system(size: size - 2)))\(Text(verbatim: " "))\(leadText)\(Text(verbatim: text))")
            .font(.system(size: size))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityLabel(Text(verbatim: [lead, text].compactMap { $0 }.joined(separator: " ")))
    }

    private var leadText: Text {
        guard let lead, !lead.isEmpty else { return Text(verbatim: "") }
        return Text(verbatim: lead + " ").fontWeight(.semibold)
    }

    /// Claude's verdict split into its first sentence ("Right.", "9 of 12.") and the rest.
    static func verdict(_ note: String) -> (lead: String?, rest: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: ". ") ?? (trimmed.hasSuffix(".") ? trimmed.range(of: ".", options: .backwards) : nil) else {
            return (nil, trimmed)
        }
        let lead = String(trimmed[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        // A long first sentence is not a verdict: keep the note as one run.
        guard lead.split(separator: " ").count <= 4 else { return (nil, trimmed) }
        return (lead, rest)
    }
}

// MARK: - Words

/// The coach's strings, built in one place (DESIGN §9 formats: days through `DayText`, clocks and
/// durations in SF Mono).
enum CoachText {
    /// "Mastery 1 of 4 · again Thu 22 Oct" (the dots' help).
    static func mastery(_ mastery: TopicMastery, locale: Locale, timeZone: TimeZone) -> String {
        let level = String(localized: "Mastery \(mastery.level) of \(CoachRules.maximumLevel)")
        guard let due = mastery.nextDue else { return level }
        return String(localized: "\(level) · again \(DayText.day(due, locale: locale, timeZone: timeZone))")
    }

    /// "Wed 21 Oct, 23:59" with the clock in SF Mono; the day alone for an all-day date.
    static func dayTime(_ date: Date, allDay: Bool = false, locale: Locale, timeZone: TimeZone) -> Text {
        let day = DayText.day(date, locale: locale, timeZone: timeZone)
        if allDay { return Text(verbatim: day) }
        return Text("\(day), \(Text(verbatim: DayText.time(date, timeZone: timeZone)).monospaced())")
    }

    /// A course's name where rows mix courses: the short name for a long one (over 16 characters
    /// or 3+ words: "CL"), as `SessionText.title` names them (DESIGN §9).
    static func shortName(_ course: Course?) -> String {
        guard let course else { return "" }
        let words = course.name.split(whereSeparator: \.isWhitespace).count
        let short = course.shortName.trimmingCharacters(in: .whitespaces)
        if (course.name.count > 16 || words >= 3), !short.isEmpty { return short }
        return course.name
    }

    /// "L2" for a numbered lecture (chips away from it).
    static func lecturePrefix(_ lecture: Lecture?) -> String? {
        lecture?.number.map { "L\($0)" }
    }

    /// "Slides 15–16", "Slide 17".
    static func slides(_ first: Int?, _ last: Int?) -> String? {
        guard let first else { return nil }
        let last = last ?? first
        return last > first ? String(localized: "Slides \(first)–\(last)") : String(localized: "Slide \(first)")
    }

    /// "12 questions" / "1 question".
    static func questions(_ count: Int) -> String {
        count == 1 ? String(localized: "1 question") : String(localized: "\(count) questions")
    }

    /// "90 points" / "1 point".
    static func points(_ count: Int) -> String {
        count == 1 ? String(localized: "1 point") : String(localized: "\(count) points")
    }

    /// A practice exam's source as the sheet names it: "All lectures", "Weakest topics", the old
    /// exam's title.
    static func source(_ scope: StudyScope) -> String {
        switch scope.kind {
        case .weakest: String(localized: "Weakest topics")
        case .oldExam: scope.oldExamTitle ?? String(localized: "Old exam")
        default: String(localized: "All lectures")
        }
    }

    /// Points as a count: "9", "4.5".
    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// A course's exam line (Study's row, Progress's eyebrow): "Exam Tue 9 Feb, 10:00", or
    /// "Second date Wed 7 Apr, 10:00" once the student sits it.
    static func examLine(_ exams: CourseExams, locale: Locale, timeZone: TimeZone) -> Text? {
        if exams.sitsSecondDate, let second = exams.second, let due = second.dueAt {
            return Text("Second date \(dayTime(due, allDay: second.isAllDay, locale: locale, timeZone: timeZone))")
        }
        guard let first = exams.first, let due = first.dueAt else { return nil }
        return Text("Exam \(dayTime(due, allDay: first.isAllDay, locale: locale, timeZone: timeZone))")
    }

    /// A seminar's next gate: "Seminar survey online Mon 26 Oct, 12:00 · 12 places".
    static func itemLine(_ item: TrackedItem, locale: Locale, timeZone: TimeZone) -> Text {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = item.details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let due = item.dueAt else { return Text(verbatim: title) }
        let when = dayTime(due, allDay: item.isAllDay, locale: locale, timeZone: timeZone)
        return details.isEmpty ? Text("\(title) \(when)") : Text("\(title) \(when) · \(details)")
    }
}

// MARK: - Durations as figures

enum CoachFigure {
    /// Progress's and the results' large figure: digits SF Mono 26 semibold primary, the units
    /// 15 pt medium secondary ("2 h 10 min", "81 h", "1 h 24 min").
    static func duration(minutes: Int) -> Text {
        let hours = minutes / 60
        let rest = minutes % 60
        let h = digits(hours)
        let m = digits(rest)
        switch (hours, rest) {
        case (0, _): return Text("\(m) min")
        case (_, 0): return Text("\(h) h")
        default: return Text("\(h) h \(m) min")
        }
    }

    /// "22%".
    static func percent(_ share: Double) -> Text {
        Text("\(digits(Int((share * 100).rounded())))%")
    }

    /// "71" (points are counts: the text font with even digits).
    static func count(_ value: Double) -> Text {
        Text(verbatim: CoachText.number(value))
            .font(.system(size: 26, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
    }

    static func digits(_ value: Int) -> Text {
        Text(verbatim: "\(value)")
            .font(.system(size: 26, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.primary)
    }
}

/// A figure over its caption (and an optional meter), 196 pt wide (mockups 14 and 19).
struct StatFigure: View {
    let value: Text
    let caption: Text
    var meter: (value: Double, color: Color)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            value
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(-0.3)
                .lineLimit(1)
            caption
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let meter {
                Meter(value: meter.value, color: meter.color)
                    .padding(.top, 3)
            }
        }
        .frame(width: 196, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hover

/// A row's quiet hover fill (DESIGN §3.3: radius 9).
struct RowHover: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(isHovered ? AnyShapeStyle(QuietFill()) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

extension View {
    func rowHover(_ isHovered: Bool) -> some View {
        modifier(RowHover(isHovered: isHovered))
    }
}

/// A sheet's course id (`.sheet(item:)`).
struct SheetCourse: Identifiable, Hashable {
    let id: Course.ID
}

// MARK: - Starting things

/// Where the coach's starts lead (`StudyStart` → a destination, a URL or the exam sheet).
@MainActor
struct CoachRouter {
    let openDestination: OpenDestinationAction
    let openURL: OpenURLAction

    /// - Returns: the course whose practice exam sheet should open, if that is where it leads.
    func route(_ start: StudyStart, items: [TrackedItem.ID: TrackedItem] = [:], trails: [TrackedItem.ID: [SourceTrailEntry]] = [:]) -> Course.ID? {
        switch start {
        case .session(let id):
            openDestination(.practice(id))
        case .lecture(let id, let page, let time):
            openDestination(.lecture(id, ReviewTarget(page: page, time: time)))
        case .item(let id):
            if let mail = trails[id]?.first(where: { $0.kind == .mail && $0.isActive })?.source.mailMessageID {
                openDestination(.mail(mail))
            } else if let course = items[id]?.courseID {
                openDestination(.course(course))
            } else {
                openDestination(.calendar)
            }
        case .url(let url):
            openURL(url)
        case .examSheet(let courseID):
            return courseID
        case .none:
            break
        }
        return nil
    }
}

/// An exam's length as exams state it: "90 min", "120 min" (mockups 14, 17, 19), never "1 h 30 min";
/// the digits in SF Mono.
enum ExamLength {
    static func string(minutes: Int) -> String {
        String(localized: "\(minutes) min")
    }

    static func text(minutes: Int) -> Text {
        Text("\(Text(verbatim: "\(minutes)").monospaced()) min")
    }
}
