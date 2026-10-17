import Courses
import StudyCore
import StudyUI
import SwiftUI

/// The New Course sheet: name, lecturer(s), languages, colour, semester and recording consent.
/// Everything else is set up in Course Settings.
public struct NewCourseView: View {
    private let onCreated: (Course) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyServices) private var services
    @FetchAll(Semester.order(by: \.lectureStart)) private var semesters
    @FetchAll(Course.order(by: \.sortOrder)) private var courses

    @State private var draft = CourseDraft()
    @State private var color = ""
    @State private var semesterID: Semester.ID?
    @State private var isCreating = false
    @FocusState private var nameFocused: Bool

    public init(onCreated: @escaping (Course) -> Void = { _ in }) {
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                form
                #if os(macOS)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                #endif
            }
            .navigationTitle("New Course")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)
                }
            }
            #endif
        }
        .onAppear(perform: prepare)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    HStack(spacing: 8) {
                        CourseDot(hex: color, size: 9)
                        TextField("Name", text: $draft.name, prompt: Text("Computational Linguistics"))
                            .labelsHidden()
                            .focused($nameFocused)
                            .onSubmit(create)
                    }
                }
                TextField("Lecturer", text: $draft.lecturers, prompt: Text("Prof. Dr. Bo Sample"))
                LabeledContent("Language") {
                    HStack(spacing: 6) {
                        Picker("Language", selection: $draft.language) {
                            ForEach(CourseDraft.languages, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("admin parts in")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Picker("Admin Language", selection: $draft.adminLanguage) {
                            ForEach(CourseDraft.languages, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                LabeledContent("Colour") {
                    ColorSwatches(hex: $color)
                }
                Picker("Semester", selection: $semesterID) {
                    ForEach(semesters) { semester in
                        Text(semester.name).tag(Semester.ID?.some(semester.id))
                    }
                }
            }
            Section {
                Toggle("Record this course", isOn: $draft.records)
            }
        }
        .formStyle(.grouped)
    }

    private var canCreate: Bool { draft.isValid && !isCreating && services != nil }

    /// The next free palette colour and the current semester.
    private func prepare() {
        if color.isEmpty {
            let used = Set(courses.map { $0.colorHex.lowercased() })
            color = CourseDraft.palette.first { !used.contains($0) } ?? CourseDraft.palette[courses.count % CourseDraft.palette.count]
        }
        if semesterID == nil, !semesters.isEmpty {
            semesterID = Semester.current(among: semesters).id
        }
        nameFocused = true
    }

    private func create() {
        guard canCreate, let services else { return }
        isCreating = true
        var draft = draft
        draft.colorHex = color.isEmpty ? nil : color
        draft.semesterID = semesterID
        let finalDraft = draft
        Task {
            defer { isCreating = false }
            do {
                let course = try await CourseLibrary(services: services).create(finalDraft)
                onCreated(course)
                dismiss()
            } catch {
                CoursesUILog.ui.error("Creating a course failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
