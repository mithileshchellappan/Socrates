import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Change on the live lecture's filing line (mockup 02): which course and class the recording
/// belongs to. The choice names the line at once and is where the finished recording is filed
/// (`AppModel.changeLiveFiling`); smart import only guesses when nothing was chosen.
struct LiveFilingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FetchAll(Course.order { ($0.sortOrder, $0.name) }) private var courses
    @State private var courseID: Course.ID?
    @State private var sessions: [LectureSession] = []
    @State private var selection: LectureSession.ID?

    /// The classes listed: a week either side of when the live lecture was opened.
    private static let window: TimeInterval = 7 * 86_400

    var body: some View {
        VStack(spacing: 0) {
            Picker("Course", selection: $courseID) {
                ForEach(courses) { course in
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
            .padding(.top, 18)
            .padding(.bottom, 10)
            List(selection: $selection) {
                ForEach(sessions) { session in
                    LiveSessionRow(session: session, isCurrent: session.id == model.live?.lectureSession?.id)
                        .tag(Optional(session.id))
                }
            }
            .frame(minHeight: 220)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Change") { change() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(courseID == nil)
            }
            .padding(16)
        }
        .frame(width: 440, height: 420)
        .onAppear {
            courseID = model.live?.course.id
            selection = model.live?.lectureSession?.id
        }
        .task(id: courseID) { await loadSessions() }
    }

    private func loadSessions() async {
        guard let services = model.services, let courseID, let openedAt = model.live?.openedAt else {
            sessions = []
            return
        }
        let found = (try? await SessionRepository(store: services.records).sessions(
            overlapping: openedAt.addingTimeInterval(-Self.window), openedAt.addingTimeInterval(Self.window), courseID: courseID
        )) ?? []
        sessions = found.filter { !$0.isCancelled }.sorted { $0.startsAt < $1.startsAt }
        if let selection, !sessions.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private func change() {
        guard let courseID, let course = courses.first(where: { $0.id == courseID }) else { return }
        model.changeLiveFiling(course: course, session: sessions.first { $0.id == selection })
        dismiss()
    }
}

/// "Lecture 3 · Mon 19 Oct 12:15 · Room 101", a checkmark on the current one.
private struct LiveSessionRow: View {
    let session: LectureSession
    let isCurrent: Bool

    var body: some View {
        let text = SessionText()
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.callout.weight(.semibold))
                .opacity(isCurrent ? 1 : 0)
                .accessibilityHidden(!isCurrent)
            Text(LiveLectureScreen.className(session))
            if !session.room.isEmpty {
                Text(session.room)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(text.day(session.startsAt))
                .foregroundStyle(.secondary)
            Text(text.time(session.startsAt))
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}
