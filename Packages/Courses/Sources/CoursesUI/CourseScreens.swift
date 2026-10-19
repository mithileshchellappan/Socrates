import Courses
import StudyCore
import StudyUI
import SwiftUI

/// A course's lectures (sidebar ▸ course ▸ Lectures, mockup 08): one row per lecture by number,
/// "L2 · Virtualization & IaaS" over its day; a row opens the lecture's review. Without lectures
/// the screen is one drop target for the course's slides and recordings; files dropped on the
/// list are filed into the course too. Import in the toolbar.
public struct CourseLecturesView: View {
    private let courseID: Course.ID
    @FetchOne private var course: Course?
    @FetchAll private var lectures: [Lecture]
    @Environment(\.openDestination) private var openDestination
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    public init(courseID: Course.ID) {
        self.courseID = courseID
        _course = FetchOne(Course.find(courseID))
        _lectures = FetchAll(Lecture.where { $0.courseID.eq(courseID) })
    }

    public var body: some View {
        Group {
            if ordered.isEmpty {
                EmptyDropPrompt(systemImage: "waveform", line: "Drop the slides (PDF) and recordings here.", target: .course(courseID))
            } else {
                CourseScreenColumn {
                    SettingsGroup("Lectures") {
                        ForEach(ordered) { lecture in
                            LectureListRow(lecture: lecture, text: SessionText(locale: locale, timeZone: timeZone)) {
                                openDestination(.lecture(lecture.id, ReviewTarget()))
                            }
                        }
                    }
                }
                .importDropTarget(.course(courseID))
            }
        }
        .screenTitle(String(localized: "Lectures"), subtitle: course?.name ?? "")
        .toolbar { CourseImportToolbarItem(courseID: courseID) }
    }

    /// By number, then date, then when they were added.
    private var ordered: [Lecture] {
        lectures.sorted { lhs, rhs in
            let left = (lhs.number ?? .max, lhs.heldAt ?? .distantFuture, lhs.createdAt)
            let right = (rhs.number ?? .max, rhs.heldAt ?? .distantFuture, rhs.createdAt)
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.2 < right.2
        }
    }
}

/// "L2 · Virtualization & IaaS" over "Tue 13 Oct"; the whole row opens the lecture.
private struct LectureListRow: View {
    let lecture: Lecture
    let text: SessionText
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .lineLimit(1)
                    if let held = lecture.heldAt {
                        Text(text.day(held))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .background(isHovered ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var title: String {
        let name = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (lecture.number, name.isEmpty) {
        case (let number?, false): return "L\(number) · \(name)"
        case (let number?, true): return "L\(number)"
        case (nil, false): return name
        case (nil, true): return String(localized: "Lecture")
        }
    }
}

/// A course's slides (sidebar ▸ course ▸ Slides): Course Settings' Slides group on its own, with
/// Change on each deck; Import in the toolbar. Without decks the screen is one drop target for the
/// course's slides; files dropped on the list are filed into the course too.
public struct CourseSlidesView: View {
    private let courseID: Course.ID
    private let changeDeck: (Deck.ID) -> Void

    @FetchOne private var course: Course?
    @Fetch private var decks: [CourseDeck]
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    public init(courseID: Course.ID, changeDeck: @escaping (Deck.ID) -> Void = { _ in }) {
        self.courseID = courseID
        self.changeDeck = changeDeck
        _course = FetchOne(Course.find(courseID))
        _decks = Fetch(wrappedValue: [], CourseDecksRequest(courseID: courseID))
    }

    public var body: some View {
        Group {
            if decks.isEmpty {
                EmptyDropPrompt(systemImage: "rectangle.on.rectangle", line: "Drop the slides (PDF) here.", target: .course(courseID))
            } else {
                CourseScreenColumn {
                    SettingsGroup("Slides") {
                        ForEach(decks) { item in
                            DeckRow(item: item, text: SessionText(locale: locale, timeZone: timeZone)) { changeDeck(item.deck.id) }
                        }
                    }
                }
                .importDropTarget(.course(courseID))
            }
        }
        .screenTitle(String(localized: "Slides"), subtitle: course?.name ?? "")
        .toolbar { CourseImportToolbarItem(courseID: courseID) }
    }
}

/// A course screen's trailing [Import +] (DESIGN 6.3, as Course Settings'): the file importer for
/// the course.
struct CourseImportToolbarItem: ToolbarContent {
    let courseID: Course.ID
    @Environment(\.importFiles) private var importFiles

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let importFiles {
                Button("Import", systemImage: "plus") { importFiles.open(to: .course(courseID)) }
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

/// One column of settings groups, as Course Settings' left column: 22 pt margins, the text
/// background.
private struct CourseScreenColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 2)
            .padding(.bottom, 22)
        }
        .background(Color.fieldBackground)
    }
}
