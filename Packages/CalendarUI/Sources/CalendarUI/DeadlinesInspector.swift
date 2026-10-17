import Courses
import StudyCore
import StudyUI
import SwiftUI

/// What the inspector asks the screen to do.
struct InspectorHandlers {
    var select: (TrackedItem) -> Void
    var confirm: (TrackedItem.ID) -> Void
    var discard: (TrackedItem.ID) -> Void
    var complete: (TrackedItem.ID) -> Void
    var addToCalendar: (TrackedItem.ID) -> Void
    var remove: (TrackedItem.ID) -> Void
    var trail: (TrackedItem.ID) -> TrailInfo
    var submit: () -> Void
}

/// The inspector "Deadlines" (mockup 06): waiting proposals as cards, then what is due from
/// today on, soonest first; the "New deadline" composer pinned at the bottom.
struct DeadlinesInspector: View {
    static let width: CGFloat = 336
    static let headerHeight: CGFloat = 52
    /// The window toolbar's inset from the trailing edge.
    static let toolbarTrailingInset: CGFloat = 11

    let data: CalendarData
    let now: Date
    let selection: CalendarSelection?
    let composer: ComposerModel
    let composerFocused: FocusState<Bool>.Binding
    let handlers: InspectorHandlers
    /// The inspector is shown. SwiftUI keeps a hidden inspector's content alive, and with it the
    /// header's toolbar item, which would stay in the toolbar beside Show Inspector.
    var isShown = true

    @Environment(\.calendarChrome) private var chrome
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var columnWidth = DeadlinesInspector.width
    @State private var hoveredID: TrackedItem.ID?

    var body: some View {
        VStack(spacing: 0) {
            if chrome == .snapshot {
                header
                    .frame(height: Self.headerHeight)
            }
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !data.proposals.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(Array(data.proposals.enumerated()), id: \.element.id) { index, proposal in
                                card(proposal, isFirst: index == 0)
                            }
                        }
                    }
                    if !data.upcoming.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(data.upcoming) { item in
                                row(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
            composerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { InspectorBackground() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .toolbar {
            if chrome == .window, isShown {
                ToolbarItem(placement: .automatic) {
                    header
                        .frame(width: max(0, columnWidth - Self.toolbarTrailingInset), alignment: .leading)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    /// "Deadlines", 13 semibold, level with the toolbar.
    private var header: some View {
        Text("Deadlines")
            .font(.system(size: 13, weight: .semibold))
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Proposals

    private func card(_ proposal: TrackedItem, isFirst: Bool) -> some View {
        let session = proposal.lectureSessionID.flatMap { data.linkedSessions[$0] }
        let course = proposal.courseID.flatMap { data.courses[$0] }
        let trail = handlers.trail(proposal.id)
        return ProposalCard(
            question: CalendarText.question(proposal),
            detail: CalendarText.proposalDetail(proposal, session: session, course: course, locale: locale, timeZone: timeZone),
            isFirstThing: isFirst,
            discard: { handlers.discard(proposal.id) },
            confirm: { handlers.confirm(proposal.id) }
        ) {
            SourceTrailButton(entries: trail.entries, now: now, inCalendar: false)
        }
    }

    // MARK: Rows

    private func row(_ item: TrackedItem) -> some View {
        let trail = handlers.trail(item.id)
        let isSelected = selection == .item(item.id)
        let isHovered = hoveredID == item.id
        return DeadlineRow(
            item: item,
            course: item.courseID.flatMap { data.courses[$0] },
            session: item.lectureSessionID.flatMap { data.linkedSessions[$0] },
            trail: trail,
            now: now,
            isSelected: isSelected,
            isHovered: isHovered
        )
        .contentShape(Rectangle())
        .onTapGesture { handlers.select(item) }
        .onHover { inside in
            if inside {
                hoveredID = item.id
            } else if hoveredID == item.id {
                hoveredID = nil
            }
        }
        .contextMenu {
            Button("Mark as Done") { handlers.complete(item.id) }
            if !item.inCalendar {
                Button("Add to Calendar") { handlers.addToCalendar(item.id) }
            }
            Divider()
            Button("Delete") { handlers.remove(item.id) }
        }
    }

    // MARK: Composer

    private var composerBar: some View {
        @Bindable var composer = composer
        return VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 6) {
                AIMark()
                TextField("", text: $composer.text, prompt: Text("New deadline"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(composerFocused)
                    .onSubmit(handlers.submit)
                    .onKeyPress(.escape) {
                        guard composer.hasText else { return .ignored }
                        composer.clear()
                        return .handled
                    }
                if composer.hasText {
                    Button(action: handlers.submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Add Deadline"))
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .frame(minHeight: 32)
            .background(Color.contentBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

/// One due item: [course dot | title (+ the exam chip) | source glyph] over its day and time
/// ("Wed 21 Oct, 23:59 · SN seminar"); Undo while hovered or selected when it went in on its own.
struct DeadlineRow: View {
    let item: TrackedItem
    let course: Course?
    let session: LectureSession?
    let trail: TrailInfo
    let now: Date
    let isSelected: Bool
    let isHovered: Bool

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            CourseDot(course: course, size: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if item.relevance == .examAdmission {
                        examChip
                    }
                }
                when
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                SourceTrailButton(
                    entries: trail.entries, now: now, header: trail.header, inCalendar: trail.inCalendar,
                    highlighted: isHovered, undo: trail.undo
                )
                .frame(minHeight: 16)
                if let undo = trail.undo, isHovered || isSelected {
                    Button(action: undo) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(height: 15)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            isSelected ? AnyShapeStyle(QuietFill()) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    /// "Wed 21 Oct, 23:59" (the clock in SF Mono), the day alone when all-day, " · SN seminar"
    /// when tied to a session.
    private var when: Text {
        guard let due = item.dueAt else { return Text(verbatim: "") }
        let day = DayText.day(due, locale: locale, timeZone: timeZone)
        var text = Text(verbatim: day)
        if !item.isAllDay {
            let time = Text(verbatim: DayText.time(due, timeZone: timeZone)).font(.mono(11.5))
            text = Text("\(text), \(time)")
        }
        if let session {
            let name = SessionText.title(of: session, courseName: course?.name ?? "", shortName: course?.shortName ?? "")
            text = Text("\(text) · \(name)")
        }
        return text.monospacedDigit()
    }

    /// The one chip a row may have: amber star + "Exam admission" on professor soft.
    private var examChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "star")
                .font(.system(size: 9.5, weight: .semibold))
            Text("Exam admission")
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.professor)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.professor.opacity(colorScheme == .dark ? 0.20 : 0.14), in: Capsule())
        .fixedSize()
    }
}

/// The inspector column's background: the system's in the window (lifted a little in dark
/// mode, as Review); the secondary background in snapshots, which have no inspector column.
private struct InspectorBackground: View {
    @Environment(\.calendarChrome) private var chrome
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch chrome {
        case .window:
            if colorScheme == .dark {
                Rectangle().fill(.white.opacity(0.025)).ignoresSafeArea()
            }
        case .snapshot:
            Rectangle().fill(.background.secondary)
        }
    }
}
