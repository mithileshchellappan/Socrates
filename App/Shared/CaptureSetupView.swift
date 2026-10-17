import CoursesUI
import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

/// Before class: which course this lecture belongs to and which deck is on screen.
/// Opening it shows the live lecture; recording starts there.
struct CaptureSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @FetchAll(Course.order { ($0.sortOrder, $0.name) }) private var courses
    @FetchAll(Deck.order { $0.importedAt.desc() }) private var decks

    @State private var courseID: Course.ID?
    @State private var records = false
    @State private var deckID: Deck.ID?
    @State private var choosesPDF = false
    @State private var createsCourse = false
    @State private var isWorking = false
    @State private var didSetInitialChoice = false

    private var course: Course? { courseID.flatMap { id in courses.first { $0.id == id } } }

    private var courseDecks: [Deck] {
        guard let course else { return [] }
        return decks.filter { $0.courseID == course.id }
    }

    private var canOpen: Bool { !isWorking && records && course != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Course", selection: coursePicker) {
                        ForEach(courses) { course in
                            Text(course.name).tag(CoursePick.course(course.id))
                        }
                        if !courses.isEmpty { Divider() }
                        Text("New Course…").tag(CoursePick.newCourse)
                    }
                    Toggle("Record this course", isOn: $records)
                        .disabled(course == nil)
                }
                Section {
                    Picker("Slides", selection: $deckID) {
                        Text("None").tag(Deck.ID?.none)
                        ForEach(courseDecks) { deck in
                            Text(deck.title.isEmpty ? deck.fileName : deck.title).tag(Deck.ID?.some(deck.id))
                        }
                    }
                    Button("Choose PDF…") { choosesPDF = true }
                        .disabled(isWorking || course == nil)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Lecture Capture")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open", action: open)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canOpen)
                }
            }
            .fileImporter(isPresented: $choosesPDF, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                Task { await addDeck(url) }
            }
            .sheet(isPresented: $createsCourse) {
                NewCourseView { created in
                    courseID = created.id
                    syncCourse(created)
                }
                .environment(\.studyServices, model.services)
            }
            .onAppear {
                guard !didSetInitialChoice else { return }
                didSetInitialChoice = true
                courseID = (courses.first { $0.recordsLectures } ?? courses.first)?.id
                syncCourse(course)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 300)
        #endif
    }

    private enum CoursePick: Hashable {
        case course(Course.ID)
        case newCourse
        case none
    }

    /// The course menu; its last item opens the New Course sheet instead of selecting.
    private var coursePicker: Binding<CoursePick> {
        Binding(
            get: { courseID.map(CoursePick.course) ?? .none },
            set: { pick in
                switch pick {
                case .course(let id):
                    courseID = id
                    syncCourse(courses.first { $0.id == id })
                case .newCourse:
                    createsCourse = true
                case .none:
                    break
                }
            }
        )
    }

    /// Consent and the default deck follow the chosen course.
    private func syncCourse(_ course: Course?) {
        records = course?.recordsLectures ?? false
        deckID = course.flatMap { course in decks.first { $0.courseID == course.id } }?.id
    }

    private func addDeck(_ url: URL) async {
        guard let course else { return }
        isWorking = true
        defer { isWorking = false }
        if let deck = await model.importDeck(at: url, courseID: course.id) {
            deckID = deck.id
        }
    }

    /// The chosen course, with consent as toggled.
    private func resolveCourse() async -> Course? {
        guard let course else { return nil }
        if course.recordsLectures != records {
            return await model.setRecordingConsent(records, for: course)
        }
        return course
    }

    private func open() {
        Task {
            isWorking = true
            defer { isWorking = false }
            guard let course = await resolveCourse(), course.recordsLectures else { return }
            let deck = deckID.flatMap { id in decks.first { $0.id == id } }
            do {
                try await model.openLiveLecture(course: course, deck: deck)
            } catch {
                model.failure = error.localizedDescription
                return
            }
            dismiss()
            #if os(macOS)
            openWindow(id: LiveLectureScene.id)
            #else
            model.isLivePresented = true
            #endif
        }
    }
}
