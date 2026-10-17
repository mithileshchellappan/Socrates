import StudyCore
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

    @State private var choice: CourseChoice = .new
    @State private var draft = CourseDraft()
    @State private var records = false
    @State private var deckID: Deck.ID?
    @State private var choosesPDF = false
    @State private var isWorking = false
    @State private var didSetInitialChoice = false

    private var course: Course? { choice.course(in: courses) }

    private var courseDecks: [Deck] {
        guard let course else { return [] }
        return decks.filter { $0.courseID == course.id }
    }

    private var canOpen: Bool {
        guard !isWorking, records else { return false }
        return choice == .new ? draft.isValid : course != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CourseChoiceSection(courses: courses, choice: $choice, draft: $draft)
                    Toggle("Record this course", isOn: $records)
                }
                Section {
                    Picker("Slides", selection: $deckID) {
                        Text("None").tag(Deck.ID?.none)
                        ForEach(courseDecks) { deck in
                            Text(deck.title.isEmpty ? deck.fileName : deck.title).tag(Deck.ID?.some(deck.id))
                        }
                    }
                    Button("Choose PDF…") { choosesPDF = true }
                        .disabled(isWorking || (choice == .new && !draft.isValid))
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
            .onAppear {
                guard !didSetInitialChoice else { return }
                didSetInitialChoice = true
                let preferred = courses.first { $0.recordingConsentAt != nil }?.id
                choice = CourseChoiceSection.initial(courses: courses, preferred: preferred)
                syncCourse()
            }
            .onChange(of: choice) {
                // Programmatic changes (a course just created) keep what the user set.
                guard !isWorking else { return }
                syncCourse()
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 300)
        #endif
    }

    /// Consent and the default deck follow the chosen course.
    private func syncCourse() {
        if let course {
            records = course.recordingConsentAt != nil
            deckID = courseDecks.first?.id
        } else {
            records = draft.records
            deckID = nil
        }
    }

    private func addDeck(_ url: URL) async {
        isWorking = true
        defer { isWorking = false }
        guard let target = await resolveCourse() else { return }
        if let deck = await model.importDeck(at: url, courseID: target.id) {
            deckID = deck.id
        }
    }

    /// The chosen course, creating a new one first, with consent as toggled.
    private func resolveCourse() async -> Course? {
        if choice == .new {
            draft.records = records
            guard draft.isValid, let created = await model.createCourse(draft) else { return nil }
            choice = .existing(created.id)
            return created
        }
        guard let course else { return nil }
        if (course.recordingConsentAt != nil) != records {
            return await model.setRecordingConsent(records, for: course)
        }
        return course
    }

    private func open() {
        Task {
            isWorking = true
            defer { isWorking = false }
            guard let course = await resolveCourse(), course.recordingConsentAt != nil else { return }
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
