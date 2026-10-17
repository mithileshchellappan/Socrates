import Processing
import StudyCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `<uuid>.lecture` folders written by live capture (declared in project.yml).
    static let lecturePackage = UTType(exportedAs: "com.example.studyportal.lecture", conformingTo: .package)
}

/// Import a recording made elsewhere (Voice Memos, a captured `.lecture`) with its slides.
/// Transcription and alignment then run in the background.
struct ImportLectureView: View {
    let preferredCourseID: Course.ID?
    /// Called with the imported lecture before the sheet closes.
    var onImported: (ImportedLecture) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FetchAll(Course.order { ($0.sortOrder, $0.name) }) private var courses

    @State private var choice: CourseChoice = .new
    @State private var draft = CourseDraft()
    @State private var recording: URL?
    @State private var slides: URL?
    @State private var picking: Picking?
    @State private var isWorking = false
    @State private var didSetInitialChoice = false

    private enum Picking: Hashable {
        case recording
        case slides

        var types: [UTType] {
            switch self {
            case .recording: [.audio, .audiovisualContent, .lecturePackage]
            case .slides: [.pdf]
            }
        }
    }

    private var isPackage: Bool { recording?.pathExtension == "lecture" }

    private var canImport: Bool {
        guard !isWorking, recording != nil else { return false }
        return choice == .new ? draft.isValid : choice.course(in: courses) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CourseChoiceSection(courses: courses, choice: $choice, draft: $draft)
                }
                Section {
                    fileRow("Recording", url: recording) { picking = .recording }
                    if !isPackage {
                        fileRow("Slides", url: slides) { picking = .slides }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import Lecture")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: runImport)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canImport)
                }
            }
            .fileImporter(
                isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                allowedContentTypes: picking?.types ?? [.audio]
            ) { result in
                guard case .success(let url) = result else { return }
                switch picking {
                case .recording: recording = url
                case .slides: slides = url
                case nil: break
                }
                picking = nil
            }
            .onAppear {
                guard !didSetInitialChoice else { return }
                didSetInitialChoice = true
                choice = CourseChoiceSection.initial(courses: courses, preferred: preferredCourseID)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 280)
        #endif
    }

    private func fileRow(_ title: LocalizedStringKey, url: URL?, choose: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            Button(url?.lastPathComponent ?? String(localized: "Choose…"), action: choose)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func runImport() {
        guard let recording else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            let course: Course?
            if choice == .new {
                course = await model.createCourse(draft)
            } else {
                course = choice.course(in: courses)
            }
            guard let course else { return }
            let source: AppModel.ImportSource = isPackage ? .capture(recording) : .recording(audio: recording, deck: slides)
            if let imported = await model.importLecture(source, courseID: course.id) {
                onImported(imported)
                dismiss()
            }
        }
    }
}
