import Filing
import StudyCore
import StudyUI
import SwiftUI

/// The glass card next to a dragged file (mockup 10): where it would go, the slide count or the
/// duration, and Change…. When unsure it lists both destinations (or the courses) and the file is
/// dropped on one of them; dropping on Change… files it and opens the change sheet.
struct DropHUD: View {
    let predictions: [FilingPrediction]
    var targeted: FilingCenter.HUDTarget?
    /// Reports each drop row's frame in the smart-import coordinate space.
    var onFrame: (FilingCenter.HUDTarget, CGRect) -> Void = { _, _ in }

    static let width: CGFloat = 236
    static let estimatedHeight: CGFloat = 92
    /// The course name on the card (mockup 10: 14 pt semibold, a step above the lecture line).
    static let titleFont = Font.system(size: 14, weight: .semibold)
    nonisolated static let space = "FilingSmartImport"

    private var lead: FilingPrediction? { predictions.first }

    var body: some View {
        if let lead {
            VStack(alignment: .leading, spacing: 0) {
                let places = predictions.count == 1 ? lead.places : Self.distinct(predictions)
                let groups = Self.groups(places)
                ForEach(Array(groups.enumerated()), id: \.offset) { offset, group in
                    if offset > 0 { Divider().padding(.vertical, 6) }
                    if group.count == 1, let entry = group.first {
                        // One place in this course: the whole block is the drop row.
                        target(.place(entry.index), isChoice: places.count > 1) { PlaceRows(place: entry.place) }
                    } else if let first = group.first {
                        // Several lectures of one course: the course once, a drop row per lecture.
                        CourseHeader(course: first.place.course, font: Self.titleFont)
                            .padding(.bottom, 2)
                        ForEach(group, id: \.index) { entry in
                            target(.place(entry.index), isChoice: true) {
                                Text(FilingText.line(entry.place))
                                    .font(.body)
                                    .lineLimit(1)
                                    .padding(.leading, 16)
                                    .padding(.vertical, 1)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    if let size = Self.size(predictions) {
                        Text(size)
                            .monospacedDigit()
                            .font(lead.duration != nil && predictions.count == 1 ? .system(.callout, design: .monospaced) : .callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    // Looks like a small button; it is a place to drop on (the HUD takes no clicks).
                    Text("Change…")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(
                            targeted == .change ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.fill),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { onFrame(.change, $0) }
                }
                .padding(.leading, 16)
                .padding(.top, 5)
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 11, trailing: 12))
            .frame(width: Self.width, alignment: .leading)
            .filingGlass()
            .accessibilityElement(children: .combine)
        }
    }

    /// A drop row: highlighted while the cursor is on it, its frame reported for hit testing.
    private func target(_ target: FilingCenter.HUDTarget, isChoice: Bool, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, isChoice ? 6 : 0)
            .padding(.vertical, isChoice ? 3 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isChoice {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(targeted == target ? Color.accentColor.opacity(0.16) : .clear)
                }
            }
            .padding(.horizontal, isChoice ? -6 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { onFrame(target, $0) }
    }

    /// Places grouped by course in order of first appearance, with their index.
    static func groups(_ places: [FilingPlace]) -> [[(index: Int, place: FilingPlace)]] {
        var groups: [[(index: Int, place: FilingPlace)]] = []
        for (index, place) in places.enumerated() {
            if let existing = groups.firstIndex(where: { $0.first?.place.course.id == place.course.id && !place.isCourseOnly }) {
                groups[existing].append((index, place))
            } else {
                groups.append([(index, place)])
            }
        }
        return groups
    }

    /// "58 slides", "1:08:13", or the number of files.
    static func size(_ predictions: [FilingPrediction]) -> String? {
        guard predictions.count == 1, let prediction = predictions.first else {
            return String(localized: "\(predictions.count) files")
        }
        return FilingText.size(pageCount: prediction.pageCount, duration: prediction.duration)
    }

    /// Several files: each destination once, best first.
    static func distinct(_ predictions: [FilingPrediction]) -> [FilingPlace] {
        var seen: [FilingPlace] = []
        for place in predictions.compactMap(\.places.first) where !seen.contains(where: { $0.destination == place.destination }) {
            seen.append(place)
        }
        return Array(seen.prefix(3))
    }
}

/// Course dot + course name, then "Lecture 3 · Wed 21 Oct" under it.
struct PlaceRows: View {
    let place: FilingPlace
    var emphasis: Font = DropHUD.titleFont

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CourseHeader(course: place.course, font: emphasis)
            if !place.isCourseOnly {
                Text(FilingText.line(place))
                    .font(.body)
                    .lineLimit(1)
                    .padding(.leading, 16)
            }
        }
    }
}

/// Course dot + course name (semibold, not the heavier headline).
struct CourseHeader: View {
    let course: Course
    var font: Font = .body.weight(.semibold)

    var body: some View {
        HStack(spacing: 7) {
            CourseDot(course: course, size: 9)
            Text(course.name)
                .font(font)
                .lineLimit(1)
        }
    }
}
