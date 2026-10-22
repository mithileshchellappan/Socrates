import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

/// Start a practice exam (mockup 17): what the questions come from (All lectures, Weakest topics,
/// each old exam, Add Old Exam…) and how long it runs (the announced length, 60 / 90 / 120 min,
/// Untimed; the faint source glyph names where the length comes from), "8 questions · 90 points",
/// Cancel and Start. A PDF dropped on the sheet is added as an old exam.
public struct PracticeExamSheet: View {
    private let courseID: Course.ID
    private let now: Date?

    @FetchOne private var course: Course?
    @FetchAll private var oldExamQuestions: [StudyQuestion]
    @Environment(\.studyCoach) private var coach
    @Environment(\.openDestination) private var openDestination
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.allLectures
    @State private var length: Length?
    @State private var preview: StudyExamPreview?
    @State private var importsOldExam = false
    @State private var isStarting = false
    @State private var isDropTargeted = false

    public init(courseID: Course.ID, now: Date? = nil) {
        self.courseID = courseID
        self.now = now
        _course = FetchOne(Course.find(courseID))
        let origin = StudyQuestionOrigin.oldExam
        _oldExamQuestions = FetchAll(StudyQuestion.where { $0.courseID.eq(courseID) && $0.origin.eq(origin) && $0.retiredAt.is(nil) })
    }

    enum Source: Hashable {
        case allLectures
        case weakest
        case oldExam(String)
        /// The menu's Add Old Exam… item (never kept as the choice).
        case add

        func scope(_ course: Course.ID) -> StudyScope {
            switch self {
            case .weakest: StudyScope(kind: .weakest, courseIDs: [course])
            case .oldExam(let title): StudyScope(kind: .oldExam, courseIDs: [course], oldExamTitle: title)
            default: StudyScope(kind: .allLectures, courseIDs: [course])
            }
        }
    }

    enum Length: Hashable {
        case minutes(Int)
        case untimed

        var minutes: Int? {
            if case .minutes(let minutes) = self { return minutes }
            return nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    CourseDot(course: course, size: 7)
                    Text(course?.name ?? "")
                        .lineLimit(1)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                Text("Practice exam")
                    .font(.title2.weight(.semibold))
            }
            VStack(spacing: 0) {
                row(String(localized: "Questions from")) {
                    Picker(selection: sourceBinding) {
                        Text("All lectures").tag(Source.allLectures)
                        Text("Weakest topics").tag(Source.weakest)
                        if !oldExams.isEmpty {
                            Divider()
                            ForEach(oldExams, id: \.self) { title in
                                Text(title).tag(Source.oldExam(title))
                            }
                        }
                        if coach != nil {
                            Divider()
                            Text("Add Old Exam…").tag(Source.add)
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Hairline()
                    .padding(.horizontal, 12)
                row(String(localized: "Length")) {
                    HStack(spacing: 6) {
                        Picker(selection: lengthBinding) {
                            ForEach(lengths, id: \.self) { option in
                                Text(label(option)).tag(option)
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Image(systemName: "doc.text")
                            .font(.system(size: 11.5))
                            .frame(width: 14, height: 14)
                            .foregroundStyle(.tertiary)
                            .help(lengthSource)
                            .accessibilityLabel(Text(lengthSource))
                    }
                }
            }
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isDropTargeted ? 1.5 : 0.5)
            }
            HStack(spacing: 8) {
                if let preview, preview.questions > 0 {
                    Text("\(CoachText.questions(preview.questions)) · \(CoachText.points(preview.points))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                    .heroSecondaryButtonStyle()
                    .keyboardShortcut(.cancelAction)
                if coach != nil {
                    Button {
                        start()
                    } label: {
                        Text("Start")
                            .fontWeight(.medium)
                            .padding(.vertical, 2)
                    }
                    .heroButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStarting || preview?.questions == 0)
                }
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(width: 404)
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }
            guard !pdfs.isEmpty, coach != nil else { return false }
            for url in pdfs { addOldExam(url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $importsOldExam, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { addOldExam(url) }
        }
        .task(id: PreviewKey(source: source, length: chosenLength)) {
            await loadPreview()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            content()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }

    // MARK: Choices

    private var oldExams: [String] {
        Array(Set(oldExamQuestions.map(\.sourceTitle).filter { !$0.isEmpty })).sorted()
    }

    private var sourceBinding: Binding<Source> {
        Binding(
            get: { source },
            set: { value in
                if value == .add {
                    importsOldExam = true
                } else {
                    source = value
                }
            }
        )
    }

    /// The announced length (the exam form's), else the profile's default within its range.
    private var announced: Int? {
        course?.rules.first { $0.kind == .examForm && $0.minutes != nil }?.minutes
    }

    private var defaultLength: Length {
        .minutes(announced ?? UniversityProfile.current.defaultExamMinutes)
    }

    private var chosenLength: Length { length ?? defaultLength }

    private var lengthBinding: Binding<Length> {
        Binding(get: { chosenLength }, set: { length = $0 })
    }

    private var lengths: [Length] {
        var minutes = [60, 90, 120]
        if let announced, !minutes.contains(announced) { minutes.insert(announced, at: 0) }
        return minutes.map(Length.minutes) + [.untimed]
    }

    private func label(_ length: Length) -> String {
        switch length {
        case .minutes(let minutes): ExamLength.string(minutes: minutes)
        case .untimed: String(localized: "Untimed")
        }
    }

    /// The glyph's help: the exam form rule when announced, else the handbook's range.
    private var lengthSource: String {
        if let rule = course?.rules.first(where: { $0.kind == .examForm && $0.isConfirmed }), !rule.text.isEmpty {
            return "\(rule.title): \(rule.text)"
        }
        let range = UniversityProfile.current.writtenExamMinutes
        return String(localized: "Written, \(range.lowerBound)–\(range.upperBound) min · form not announced")
    }

    // MARK: Actions

    private struct PreviewKey: Hashable {
        var source: Source
        var length: Length
    }

    private func loadPreview() async {
        guard let coach else { return }
        do {
            preview = try await coach.previewExam(course: courseID, source: source.scope(courseID), minutes: chosenLength.minutes)
        } catch {
            CoachUILog.ui.error("Exam preview failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func start() {
        guard let coach, !isStarting else { return }
        isStarting = true
        let scope = source.scope(courseID)
        let minutes = chosenLength.minutes
        let courseID = courseID
        let open = openDestination
        Task {
            defer { isStarting = false }
            do {
                let session = try await coach.startExam(course: courseID, source: scope, minutes: minutes)
                dismiss()
                open(.practice(session))
            } catch {
                CoachUILog.ui.error("Start exam failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func addOldExam(_ url: URL) {
        guard let coach else { return }
        let courseID = courseID
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await coach.addOldExam(course: courseID, file: url)
            } catch {
                CoachUILog.ui.error("Add Old Exam failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
