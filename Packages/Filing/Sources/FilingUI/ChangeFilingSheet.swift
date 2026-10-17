import Filing
import StudyCore
import StudyUI
import SwiftUI

/// Where a filed file goes instead: course, then the course's lectures and sessions (past and
/// upcoming) or a new lecture. Keyboard first: the list has focus, ↑/↓ choose, ⏎ moves, ⎋ cancels.
public struct ChangeFilingSheet: View {
    let filingID: Filing.ID
    let center: FilingCenter

    @Environment(\.dismiss) private var dismiss
    @State private var loaded: Loaded?
    @State private var courseID: Course.ID?
    @State private var places: [FilingPlace] = []
    @State private var selection: Choice?
    @State private var isMoving = false
    @FocusState private var listFocused: Bool

    public init(filingID: Filing.ID, center: FilingCenter) {
        self.filingID = filingID
        self.center = center
    }

    enum Choice: Hashable {
        case place(FilingDestination)
        case newLecture
    }

    struct Loaded {
        var filing: Filing
        var current: FilingPlace?
        var courses: [Course]
        /// "58 slides" or "44:34".
        var size: String?
        var isRecording: Bool
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            if let loaded {
                Picker("Course", selection: $courseID) {
                    ForEach(loaded.courses) { course in
                        Label {
                            Text(course.name)
                        } icon: {
                            CourseDot(course: course, size: 9)
                        }
                        .tag(Optional(course.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            List(selection: $selection) {
                ForEach(places, id: \.destination) { place in
                    PlaceListRow(place: place, isCurrent: place.destination == currentDestination)
                        .tag(Choice.place(place.destination))
                }
                Label("New Lecture", systemImage: "plus")
                    .tag(Choice.newLecture)
            }
            .focused($listFocused)
            .frame(minHeight: 220)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(loaded?.filing.courseID == nil ? "File" : "Move") { Task { await move() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canMove)
            }
            .padding(16)
        }
        .frame(width: 440, height: 480)
        .task { await load() }
        .onChange(of: courseID) { _, id in
            Task { await loadPlaces(id) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            FileTile(kind: loaded?.filing.kind, course: loaded?.current?.course)
            VStack(alignment: .leading, spacing: 2) {
                Text(loaded?.filing.fileName ?? " ")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = loaded?.size {
                    Text(size)
                        .font(loaded?.isRecording == true ? .system(.callout, design: .monospaced) : .callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var currentDestination: FilingDestination? {
        loaded?.filing.lectureID.map { .lecture($0) }
    }

    private var canMove: Bool {
        guard !isMoving, let selection, courseID != nil else { return false }
        if case .place(let destination) = selection, destination == currentDestination { return false }
        return true
    }

    // MARK: - Data

    private func load() async {
        guard let filing = try? await center.service.filing(filingID) else { return }
        let current = try? await center.service.place(of: filing)
        let courses = (try? await center.service.courses()) ?? []
        let size = try? await center.service.size(of: filing)
        loaded = Loaded(
            filing: filing, current: current, courses: courses,
            size: FilingText.size(pageCount: size?.pageCount, duration: size?.duration), isRecording: size?.duration != nil
        )
        let course = filing.courseID ?? filing.candidates.first?.courseID ?? courses.first?.id
        courseID = course
        await loadPlaces(course)
        listFocused = true
    }

    private func loadPlaces(_ courseID: Course.ID?) async {
        guard let courseID else { places = []; return }
        places = (try? await center.service.places(courseID: courseID)) ?? []
        if let current = currentDestination, places.contains(where: { $0.destination == current }) {
            selection = .place(current)
        } else {
            selection = places.first { $0.isNewLecture && ($0.date ?? .distantPast) >= Date() }.map { .place($0.destination) }
                ?? places.last.map { .place($0.destination) } ?? .newLecture
        }
    }

    private func move() async {
        guard let selection, let courseID else { return }
        isMoving = true
        switch selection {
        case .place(let destination):
            await center.change(filingID, to: destination, newLectureIn: nil)
        case .newLecture:
            await center.change(filingID, to: nil, newLectureIn: courseID)
        }
        isMoving = false
        dismiss()
    }
}

/// "✓ Lecture 2 · Virtualization Basics            Tue 13 Oct 16:15"
struct PlaceListRow: View {
    let place: FilingPlace
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.callout.weight(.semibold))
                .opacity(isCurrent ? 1 : 0)
                .accessibilityHidden(!isCurrent)
            Text(FilingText.lecture(place))
            if place.number != nil, !place.title.isEmpty {
                Text(place.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let date = place.date {
                Text(FilingText.day(date))
                    .foregroundStyle(.secondary)
                if !place.isWholeDay {
                    Text(FilingText.time(date))
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
    }
}
