import SwiftUI

/// A dated row in a list that mixes courses (Today's Coming up, mockup 01; docs/DESIGN.md §7.3):
/// [10 pt marker column | title (13 medium) over an optional 12 pt grey gloss | a 100 pt trailing
/// column with the day (13) over the time (SF Mono 11.5, secondary)]. The marker is a 4 pt course
/// bar (radius 2) for a class or event, or a `DueRing` for something due (§4.8). The accessory —
/// the source glyph — follows the row's last line. A hovered row gets the quiet fill (radius 9);
/// the list hides the separators beside it.
public struct CourseBarRow<Accessory: View>: View {
    public enum Marker: Hashable, Sendable {
        /// A class or event.
        case bar
        /// Something due.
        case ring
    }

    private let color: Color
    private let marker: Marker
    private let title: String
    private let gloss: String?
    private let examStar: Bool
    private let day: String
    private let time: String?
    private let dayNote: String?
    private let isStruck: Bool
    private let isHovered: Bool
    private let accessory: Accessory

    /// - Parameters:
    ///   - color: the course colour (bar or ring).
    ///   - gloss: one grey line under the title (AI text, no sparkle).
    ///   - examStar: the amber `star` before the gloss (required for exam admission).
    ///   - time: a clock time or range under the day, in SF Mono; nil for an all-day row.
    ///   - dayNote: a 12 pt text line under the day ("and Fri 13 Nov").
    ///   - isStruck: cancelled: struck through in tertiary.
    public init(
        color: Color,
        marker: Marker = .bar,
        title: String,
        gloss: String? = nil,
        examStar: Bool = false,
        day: String,
        time: String? = nil,
        dayNote: String? = nil,
        isStruck: Bool = false,
        isHovered: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.color = color
        self.marker = marker
        self.title = title
        self.gloss = gloss.flatMap { $0.isEmpty ? nil : $0 }
        self.examStar = examStar
        self.day = day
        self.time = time
        self.dayNote = dayNote
        self.isStruck = isStruck
        self.isHovered = isHovered
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            markerView
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                if let gloss {
                    titleText
                    HStack(spacing: 6) {
                        HStack(spacing: 5) {
                            if examStar {
                                Image(systemName: "star")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color.professor)
                                    .frame(width: 12, height: 12)
                                    .accessibilityLabel(Text("Exam admission"))
                            }
                            Text(gloss)
                                .lineLimit(1)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 16)
                        accessory
                    }
                } else {
                    HStack(spacing: 6) {
                        titleText
                        accessory
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(day)
                    .frame(minHeight: 18)
                if let time {
                    Text(time)
                        .font(.mono(11.5))
                        .monospacedDigit()
                        .foregroundStyle(isStruck ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .frame(minHeight: 16)
                }
                if let dayNote {
                    Text(dayNote)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 16)
                }
            }
            .strikethrough(isStruck)
            .foregroundStyle(isStruck ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 100, alignment: .trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 9, style: .continuous)
        )
        .contentShape(.rect(cornerRadius: 9, style: .continuous))
    }

    private var titleText: some View {
        Text(title)
            .fontWeight(.medium)
            .strikethrough(isStruck)
            .foregroundStyle(isStruck ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .frame(minHeight: 18)
    }

    @ViewBuilder
    private var markerView: some View {
        switch marker {
        case .bar:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
        case .ring:
            DueRing(color: color)
                .padding(.top, 4)
        }
    }
}

extension CourseBarRow where Accessory == EmptyView {
    public init(
        color: Color,
        marker: Marker = .bar,
        title: String,
        gloss: String? = nil,
        examStar: Bool = false,
        day: String,
        time: String? = nil,
        dayNote: String? = nil,
        isStruck: Bool = false,
        isHovered: Bool = false
    ) {
        self.init(
            color: color, marker: marker, title: title, gloss: gloss, examStar: examStar, day: day, time: time,
            dayNote: dayNote, isStruck: isStruck, isHovered: isHovered
        ) {
            EmptyView()
        }
    }
}
