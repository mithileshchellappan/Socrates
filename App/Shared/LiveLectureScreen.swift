import CaptureUI
import Courses
import StudyCore
import StudyUI
import SwiftUI

/// The live lecture for the session the app model owns, with its filing line under the slide.
struct LiveLectureScreen: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var changesFiling = false

    var body: some View {
        if let live = model.live {
            LiveLectureView(
                session: live.session,
                context: LiveLectureContext(
                    title: Self.title(for: live),
                    color: Color(hex: live.course.colorHex),
                    onChange: { changesFiling = true },
                    onShowSidebar: showSidebar
                )
            )
            .sheet(isPresented: $changesFiling) {
                LiveFilingSheet()
                    .environment(model)
            }
            #if os(macOS)
            // The course is in the line under the slide; the title only names the window in the
            // Window menu (mockup 02: no toolbar title).
            .navigationTitle(live.course.name)
            .toolbar(removing: .title)
            #endif
        } else {
            ContentUnavailableView {
                Image(systemName: "record.circle")
            }
        }
    }

    /// The sidebar button (mockup 02: this window's sidebar is collapsed): on the Mac the main
    /// window, with the library's sidebar, comes forward; recording goes on. iPhone and iPad have
    /// the live lecture over the main screen, so nothing to show.
    private var showSidebar: (() -> Void)? {
        #if os(macOS)
        { [openWindow] in MainWindow.bringForward(openWindow: openWindow) }
        #else
        nil
        #endif
    }

    /// "Data Centers · Lecture 2 · Virtualization Basics · Tue 13 Oct, 16:15 · Room 101": the
    /// class from its session (number, start, room) when the course has one now, else when the
    /// live lecture was opened.
    static func title(for live: AppModel.LiveCapture, text: SessionText = SessionText()) -> String {
        let session = live.lectureSession
        var parts = [live.course.name]
        if let session { parts.append(className(session)) }
        if let title = live.deck?.title, !title.isEmpty { parts.append(title) }
        let start = session?.startsAt ?? live.openedAt
        parts.append("\(text.day(start)), \(text.time(start))")
        if let room = session?.room.trimmingCharacters(in: .whitespaces), !room.isEmpty { parts.append(room) }
        return parts.joined(separator: " · ")
    }

    /// "Lecture 2", "Exercise 1", "Seminar".
    static func className(_ session: LectureSession) -> String {
        if session.kind == .lecture, let number = session.number { return String(localized: "Lecture \(number)") }
        return [session.kind.displayName, session.number.map(String.init)].compactMap(\.self).joined(separator: " ")
    }
}
