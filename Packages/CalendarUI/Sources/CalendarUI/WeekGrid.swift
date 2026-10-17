import StudyCore
import StudyUI
import SwiftUI

/// A course's (or another calendar's) colour and the recipes over it (docs/DESIGN.md §3.1).
struct GridTint {
    let base: Color

    init(hex: String?) {
        base = hex.flatMap { Color(hex: $0) } ?? .accentColor
    }

    /// Text on a course tint.
    var text: Color { base.mix(with: .primary, by: 0.35) }
    /// The room line in an event.
    var subText: Color { base.mix(with: .secondary, by: 0.6) }

    /// The course tint, opaque over the content surface.
    func fill(_ opacity: Double) -> some View {
        ZStack {
            Color.calendarContent
            base.opacity(opacity)
        }
    }
}

/// An item's source trail as the popover shows it.
struct TrailInfo {
    var entries: [SourceTrailEntry]
    /// The item's detail ("Dropping out after this costs 1 of 3 attempts").
    var header: String?
    var inCalendar: Bool
    var undo: (@MainActor @Sendable () -> Void)?

    static let none = TrailInfo(entries: [], header: nil, inCalendar: false, undo: nil)
}

/// What the grid asks the screen to do.
struct GridHandlers {
    var select: (CalendarSelection?) -> Void
    var open: (WeekPlan.Event) -> Void
    var cancelSession: (LectureSession.ID) -> Void
    var restoreSession: (LectureSession.ID) -> Void
    var trail: (TrackedItem.ID) -> TrailInfo
    var now: Date
}

// MARK: - Header and all-day row

/// "Mon 19" … "Fri 23" (weekday 11 secondary, date 15 semibold, bottom-aligned), Saturday and
/// Sunday stacked small; today's date in the accent.
struct WeekHeader: View {
    let week: CalendarWeek
    let columns: WeekColumns
    let today: CalendarDay
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: GridMetrics.gutter, height: GridMetrics.headerHeight)
            ForEach(Array(week.days.enumerated()), id: \.offset) { index, day in
                let isToday = day == today
                Group {
                    if index < 5 {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(verbatim: CalendarText.weekday(day, locale: locale))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(verbatim: "\(day.day)")
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        }
                        .padding(.leading, 7)
                        .padding(.bottom, 7)
                        .frame(width: columns.width(index), height: GridMetrics.headerHeight, alignment: .bottomLeading)
                    } else {
                        VStack(spacing: 1) {
                            Text(verbatim: CalendarText.weekday(day, locale: locale))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(verbatim: "\(day.day)")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                        .padding(.bottom, 6)
                        .frame(width: columns.width(index), height: GridMetrics.headerHeight, alignment: .bottom)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: columns.width, height: GridMetrics.headerHeight, alignment: .leading)
    }
}

/// The all-day row: the "all-day" gutter label and the pills.
struct AllDayRow: View {
    let plan: WeekPlan
    let columns: WeekColumns
    let height: CGFloat
    let selection: CalendarSelection?
    let handlers: GridHandlers

    var body: some View {
        HStack(spacing: 0) {
            Text("all-day")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .padding(.trailing, 6)
                .frame(width: GridMetrics.gutter, height: height, alignment: .topTrailing)
            ForEach(0..<7, id: \.self) { index in
                VStack(alignment: .leading, spacing: GridMetrics.pillSpacing) {
                    ForEach(plan.pills.filter { $0.day == index }) { pill in
                        PillView(pill: pill, isSelected: pill.itemID.map { selection == .item($0) } ?? false, handlers: handlers)
                    }
                    if let preview = plan.preview, preview.minute == nil, preview.day == index {
                        PreviewPill(preview: preview)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 2)
                .padding(.trailing, 3)
                .frame(width: columns.width(index), height: height, alignment: .topLeading)
                .background(index >= 5 ? AnyShapeStyle(QuietFill()) : AnyShapeStyle(.clear))
                .overlay(alignment: .leading) { Hairline(.vertical) }
            }
        }
        .frame(width: columns.width, height: height, alignment: .leading)
    }
}

/// An all-day item (or one due at 23:59): 19 pt, radius 5, 11 medium, course tint 14 %.
private struct PillView: View {
    let pill: WeekPlan.Pill
    let isSelected: Bool
    let handlers: GridHandlers

    var body: some View {
        let tint = GridTint(hex: pill.colorHex)
        let label = Text(pill.title)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: GridMetrics.pillHeight)
            .foregroundStyle(isSelected ? Color.white : tint.text)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.base)
                } else {
                    tint.fill(0.14).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        if let itemID = pill.itemID {
            label
                .contentShape(Rectangle())
                .onTapGesture { handlers.select(.item(itemID)) }
                .trailPopover(handlers.trail(itemID), now: handlers.now)
                .accessibilityAddTraits(.isButton)
        } else {
            label
        }
    }
}

/// The composer's all-day parse, dashed.
private struct PreviewPill: View {
    let preview: WeekPlan.Preview

    var body: some View {
        let tint = GridTint(hex: preview.colorHex)
        Text(preview.title)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: GridMetrics.pillHeight)
            .background(Color.calendarContent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(tint.base.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Body

/// The 24 hours (56 pt each) with lines, labels, events, due lines, the preview and the now line.
struct WeekBody: View {
    let plan: WeekPlan
    let columns: WeekColumns
    /// Today's column and the minute now, when this week holds today.
    let now: (day: Int, minute: Int)?
    let selection: CalendarSelection?
    let handlers: GridHandlers

    var body: some View {
        let width = columns.width
        ZStack(alignment: .topLeading) {
            // Weekend fills and column lines.
            ForEach(5..<7, id: \.self) { index in
                Rectangle()
                    .fill(QuietFill())
                    .frame(width: GridMetrics.weekendWidth, height: GridMetrics.bodyHeight)
                    .offset(x: columns.x(index))
            }
            ForEach(0..<7, id: \.self) { index in
                Hairline(.vertical)
                    .frame(height: GridMetrics.bodyHeight)
                    .offset(x: columns.x(index))
            }
            // Hour lines and labels.
            ForEach(0...24, id: \.self) { hour in
                Hairline()
                    .frame(width: max(0, width - GridMetrics.gutter))
                    .offset(x: GridMetrics.gutter, y: GridMetrics.y(minute: hour * 60))
                if hour < 24 {
                    Text(verbatim: String(format: "%02d:00", hour))
                        .font(.mono(10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: GridMetrics.gutter - 6, height: 14, alignment: .trailing)
                        .offset(y: GridMetrics.y(minute: hour * 60) - 7)
                }
            }

            ForEach(plan.events) { event in
                let laneWidth = (columns.width(event.day) - 5) / CGFloat(event.lanes)
                let top = GridMetrics.y(minute: event.startMinute)
                let height = max(18, GridMetrics.y(minute: event.endMinute) - top - 1)
                EventView(event: event, isSelected: event.sessionID.map { selection == .session($0) } ?? false, handlers: handlers)
                    .frame(width: max(0, laneWidth - (event.lanes > 1 ? 1 : 0)), height: height)
                    .offset(x: columns.x(event.day) + 2 + CGFloat(event.lane) * laneWidth, y: top)
            }

            ForEach(plan.dues) { due in
                DueView(due: due, isSelected: selection == .item(due.id), handlers: handlers)
                    .frame(width: columns.width(due.day))
                    .offset(x: columns.x(due.day), y: GridMetrics.y(minute: due.minute))
            }

            if let preview = plan.preview, let minute = preview.minute {
                PreviewMark(preview: preview)
                    .frame(width: columns.width(preview.day))
                    .offset(x: columns.x(preview.day), y: GridMetrics.y(minute: minute))
            }

            if let now {
                NowLine()
                    .frame(width: columns.width(now.day))
                    .offset(x: columns.x(now.day), y: GridMetrics.y(minute: now.minute))
            }
        }
        .frame(width: width, height: GridMetrics.bodyHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { handlers.select(nil) }
    }
}

/// A session (or another calendar's event): radius 6, course tint 15 %, a 3 pt course bar,
/// 11 pt course text — mono range, semibold title, the room; a waiting proposal as a dashed tag.
private struct EventView: View {
    let event: WeekPlan.Event
    let isSelected: Bool
    let handlers: GridHandlers

    var body: some View {
        let tint = GridTint(hex: event.colorHex)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let textColor: AnyShapeStyle = event.isCancelled
            ? AnyShapeStyle(.tertiary)
            : (isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(tint.text))
        let content = VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: event.time)
                .font(.mono(11))
                .monospacedDigit()
                .opacity(0.85)
            Text(event.title)
                .font(.system(size: 11, weight: .semibold))
            if let subtitle = event.subtitle {
                Text(subtitle)
                    .foregroundStyle(isSelected || event.isCancelled ? textColor : AnyShapeStyle(tint.subText))
            }
            if let tag = event.proposalTag, !event.isCancelled {
                Text(tag)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.white.opacity(0.8) : tint.base.opacity(0.75),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                    }
                    .padding(.top, 1)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .strikethrough(event.isCancelled)
        .foregroundStyle(textColor)
        .padding(.top, 3)
        .padding(.bottom, 3)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack(alignment: .leading) {
                if isSelected {
                    tint.base
                } else {
                    tint.fill(event.isCancelled ? 0.07 : 0.15)
                }
                Rectangle()
                    .fill(tint.base.opacity(event.isCancelled ? 0.4 : 1))
                    .frame(width: 3)
            }
        }
        .clipShape(shape)

        if let sessionID = event.sessionID {
            content
                .contentShape(shape)
                .onTapGesture { handlers.select(.session(sessionID)) }
                .simultaneousGesture(TapGesture(count: 2).onEnded { handlers.open(event) })
                .contextMenu {
                    if event.isCancelled {
                        Button("Restore Session") { handlers.restoreSession(sessionID) }
                    } else {
                        Button("Cancel Session") { handlers.cancelSession(sessionID) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        } else {
            // Another calendar's event: read-only.
            content
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
        }
    }
}

/// A timed due item: a 2 pt course line, an 8 pt dot on the column's leading edge, the title
/// as a tag under the line (filled when selected).
private struct DueView: View {
    let due: WeekPlan.Due
    let isSelected: Bool
    let handlers: GridHandlers

    var body: some View {
        let tint = GridTint(hex: due.colorHex)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(tint.base)
                .frame(height: 2)
            Circle()
                .fill(tint.base)
                .frame(width: 8, height: 8)
                .offset(x: -4, y: -3)
            Text(due.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isSelected ? Color.white : tint.text)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.base)
                    } else {
                        tint.fill(0.15).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { handlers.select(.item(due.id)) }
                .trailPopover(handlers.trail(due.id), now: handlers.now)
                .padding(.horizontal, 3)
                .offset(y: 5)
                .accessibilityAddTraits(.isButton)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The composer's timed parse: a dashed 1.5 pt line, a hollow dot, a dashed tag above the line.
private struct PreviewMark: View {
    let preview: WeekPlan.Preview
    /// An 11 pt line with 3 pt above and below.
    static let tagHeight: CGFloat = 20

    var body: some View {
        let tint = GridTint(hex: preview.colorHex)
        ZStack(alignment: .topLeading) {
            Line()
                .stroke(tint.base, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(height: 1.5)
            Circle()
                .fill(Color.calendarContent)
                .overlay { Circle().strokeBorder(tint.base, lineWidth: 1.5) }
                .frame(width: 8, height: 8)
                .offset(x: -4, y: -3.25)
            Text(preview.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.calendarContent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(tint.base.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                .padding(.horizontal, 3)
                .offset(y: -(Self.tagHeight + 4))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// A horizontal line through the middle of its frame.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// The current time in today's column: a 1 pt accent line with a 6 pt dot at its leading end.
private struct NowLine: View {
    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.tint)
                .frame(height: 1)
            Circle()
                .fill(.tint)
                .frame(width: 6, height: 6)
                .offset(x: -3)
        }
        .frame(height: 6)
        .offset(y: -3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Source popover on hover

extension View {
    /// Opens the item's source popover while the pointer rests on the view (on tap on iPad and
    /// iPhone), with the in-calendar check and Undo in its footer.
    func trailPopover(_ trail: TrailInfo, now: Date) -> some View {
        modifier(TrailPopover(trail: trail, now: now))
    }
}

private struct TrailPopover: ViewModifier {
    let trail: TrailInfo
    let now: Date
    @State private var isPresented = false
    @State private var overAnchor = false
    @State private var overPopover = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        if trail.entries.contains(where: \.isActive) {
            content
                #if os(macOS)
                .onHover { inside in
                    overAnchor = inside
                    settle()
                }
                #else
                .simultaneousGesture(TapGesture().onEnded { isPresented = true })
                #endif
                .popover(isPresented: $isPresented, arrowEdge: .leading) {
                    let presented = $isPresented
                    SourceTrailPopover(
                        entries: trail.entries, now: now, header: trail.header, inCalendar: trail.inCalendar,
                        undo: trail.undo.map { undo in { @MainActor @Sendable in undo(); presented.wrappedValue = false } }
                    )
                    #if os(macOS)
                    .onHover { inside in
                        overPopover = inside
                        settle()
                    }
                    #endif
                }
        } else {
            content
        }
    }

    /// Opens after a short rest, closes a moment after the pointer left both (as
    /// `SourceTrailButton`).
    private func settle() {
        pending?.cancel()
        let wanted = overAnchor || overPopover
        guard wanted != isPresented else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: wanted ? .milliseconds(350) : .milliseconds(250))
            guard !Task.isCancelled else { return }
            isPresented = wanted
        }
    }
}
