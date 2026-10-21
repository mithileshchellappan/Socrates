import Filing
import ImageIO
import Materials
import Observation
import StudyCore
import StudyUI
import SwiftUI

// mt (docs/plan-materials.md §2.4, the user's approved behaviour change): a PDF dropped anywhere
// on the window, a course's sidebar row or File ▸ Import… goes through the classifier first
// (`MaterialClassifier`, code, ≤ 300 ms). A book or a paper becomes a material of the course it
// was dropped on (a course's row, a lecture's or session's row, the course whose screen shows),
// else of the course its title, authors or glossary match, else it waits with a needs-course
// toast. Slides and everything else are filed as today. While such a PDF is dragged the HUD says
// "Materials · Book" and "640 pages"; after the drop a filed toast's shape: the cover as its
// tile, the course, "Book · 640 pages", Undo, and Change… (each course's Materials, and Slides to
// file it as a deck instead).

/// The window's way to the course materials (`FilingCenter.materials`, set by the app over its
/// `MaterialLibrary`, Mac only; nil: PDFs are filed as before).
@MainActor
@Observable
public final class MaterialDropHandler {
    /// One dropped book or paper.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var fileName: String
        var reading: MaterialClassifier.Reading
        /// The course it went to (nil: none fits yet).
        var course: Course?
        var material: CourseMaterial?
        var cover: URL?
        var failure: String?
        var isWorking = false
    }

    let library: MaterialLibrary
    private(set) var toasts: [Toast] = []
    @ObservationIgnored var toastLifetime: Duration = .seconds(8)
    static let maximumToasts = 3
    @ObservationIgnored private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var hovered: Set<UUID> = []

    public init(library: MaterialLibrary) {
        self.library = library
    }

    /// The PDFs among `urls` that are books or papers, with what was read; the rest stay.
    nonisolated static func classify(_ urls: [URL]) async -> (materials: [(URL, MaterialClassifier.Reading)], rest: [URL]) {
        var materials: [(URL, MaterialClassifier.Reading)] = []
        var rest: [URL] = []
        for url in urls {
            guard url.pathExtension.lowercased() == "pdf", let reading = await MaterialClassifier.read(pdfAt: url), reading.kind.isMaterial else {
                rest.append(url)
                continue
            }
            materials.append((url, reading))
        }
        return (materials, rest)
    }

    /// Takes the books and papers among `urls` (to `course`, else the course they match), shows a
    /// toast for each, and returns the rest for smart import.
    func take(_ urls: [URL], course: Course.ID?, courses: [Course]) async -> [URL] {
        let (materials, rest) = await Self.classify(urls)
        for (url, reading) in materials {
            let target = course.flatMap { id in courses.first { $0.id == id } }
                ?? MaterialCourseMatch.course(for: reading, fileName: url.lastPathComponent, among: courses)
            var toast = Toast(url: url, fileName: url.lastPathComponent, reading: reading, course: target)
            if let target {
                do {
                    let added = try await library.add(files: [url], to: target.id, as: reading.kind.materialKind)
                    toast.material = added.first
                    if let material = added.first { toast.cover = await library.coverURL(of: material) }
                } catch {
                    FilingCenter.log.error("Adding a dropped material failed: \(String(describing: error), privacy: .private)")
                    toast.failure = (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn’t finish")
                }
            }
            show(toast)
        }
        return rest
    }

    /// Undo: the drop's material goes (no Edit ▸ Undo entry, as a filed toast's Undo).
    func undo(_ id: Toast.ID) async {
        guard let index = toasts.firstIndex(where: { $0.id == id }), let material = toasts[index].material else { return }
        toasts[index].isWorking = true
        do {
            _ = try await library.delete([material.id])
        } catch {
            FilingCenter.log.error("Undoing a dropped material failed: \(String(describing: error), privacy: .public)")
        }
        dismiss(id)
    }

    /// Change… → a course's Materials: added there (a needs-course toast) or moved there.
    func choose(_ id: Toast.ID, course: Course) async {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        toasts[index].isWorking = true
        let toast = toasts[index]
        do {
            if let material = toast.material {
                let moved = try await library.move(material.id, to: course.id)
                update(id) { $0.material = moved ?? $0.material }
            } else {
                let added = try await library.add(files: [toast.url], to: course.id, as: toast.reading.kind.materialKind)
                var cover: URL?
                if let first = added.first { cover = await library.coverURL(of: first) }
                update(id) {
                    $0.material = added.first
                    $0.cover = cover
                }
            }
            update(id) {
                $0.course = course
                $0.failure = nil
            }
        } catch {
            update(id) { $0.failure = (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn’t finish") }
        }
        update(id) { $0.isWorking = false }
        scheduleDismissal(id)
    }

    /// Change… → Slides: the material goes and the PDF is filed as a deck of that course.
    func fileAsSlides(_ id: Toast.ID, course: Course, center: FilingCenter) async {
        guard let toast = toasts.first(where: { $0.id == id }) else { return }
        update(id) { $0.isWorking = true }
        if let material = toast.material { _ = try? await library.delete([material.id]) }
        dismiss(id)
        await center.fileAsDeck([toast.url], to: .course(course.id))
    }

    // MARK: Toasts

    private func show(_ toast: Toast) {
        toasts.append(toast)
        while toasts.count > Self.maximumToasts, let oldest = toasts.first {
            dismiss(oldest.id)
        }
        scheduleDismissal(toast.id)
    }

    func dismiss(_ id: Toast.ID) {
        dismissTasks.removeValue(forKey: id)?.cancel()
        hovered.remove(id)
        toasts.removeAll { $0.id == id }
    }

    func setHovering(_ id: Toast.ID, _ isHovering: Bool) {
        if isHovering {
            hovered.insert(id)
            dismissTasks.removeValue(forKey: id)?.cancel()
        } else {
            hovered.remove(id)
            scheduleDismissal(id)
        }
    }

    private func update(_ id: Toast.ID, _ change: (inout Toast) -> Void) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        change(&toasts[index])
    }

    /// Filed toasts leave after 8 s while not hovered; one waiting for a course stays.
    private func scheduleDismissal(_ id: Toast.ID) {
        guard let toast = toasts.first(where: { $0.id == id }), !toast.isWorking, toast.course != nil || toast.failure != nil,
              !hovered.contains(id)
        else { return }
        dismissTasks[id]?.cancel()
        let lifetime = toastLifetime
        dismissTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    // MARK: Previews

    /// Shows a toast without adding anything (the app's parity screenshots); it stays until
    /// dismissed.
    public func preview(fileName: String, kind: MaterialKind, pageCount: Int, course: Course?, cover: URL? = nil) {
        let classified: MaterialClassifier.Kind = kind == .paper ? .paper : .book
        toasts.append(Toast(
            url: URL(fileURLWithPath: "/\(fileName)"), fileName: fileName,
            reading: MaterialClassifier.Reading(kind: classified, pageCount: pageCount), course: course, cover: cover
        ))
    }
}

/// What a dragged book or paper would do (the HUD): the course it goes to and what it is.
public struct MaterialPrediction: Equatable, Sendable {
    public var course: Course?
    public var kind: MaterialClassifier.Kind
    public var pageCount: Int

    public init(course: Course?, kind: MaterialClassifier.Kind, pageCount: Int) {
        self.course = course
        self.kind = kind
        self.pageCount = pageCount
    }
}

// MARK: - Matching a window drop to a course

/// The course a book or paper dropped on the window belongs to (no course screen showed): its
/// title, file name and first page matched against each course's name and short name (the whole
/// name), its lecturers' surnames (the PDF's authors) and glossary terms. One clear best, else nil.
enum MaterialCourseMatch {
    static func course(for reading: MaterialClassifier.Reading, fileName: String, among courses: [Course]) -> Course? {
        let titleWords = Set(words([reading.title ?? "", (fileName as NSString).deletingPathExtension, String(reading.leadingText.prefix(400))]
            .joined(separator: " ")))
        let authorWords = Set(words((reading.author ?? "") + " " + String(reading.leadingText.prefix(1_500))))
        let textWords = Set(words(reading.leadingText))
        var scored: [(Course, Int)] = []
        for course in courses {
            var score = 0
            let name = words(course.name).filter { $0.count > 2 }
            if !name.isEmpty, Set(name).isSubset(of: titleWords) { score += 3 }
            let short = words(course.shortName)
            if !short.isEmpty, short.count <= 2, Set(short).isSubset(of: titleWords) { score += 1 }
            for professor in course.professors {
                if let surname = words(professor).last, surname.count > 2, authorWords.contains(surname) { score += 2 }
            }
            let glossary = course.glossaryTerms.filter { term in
                let termWords = words(term)
                return !termWords.isEmpty && Set(termWords).isSubset(of: textWords)
            }.count
            score += min(3, glossary)
            if score > 0 { scored.append((course, score)) }
        }
        scored.sort { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= 2 else { return nil }
        if scored.count > 1, scored[1].1 == best.1 { return nil }
        return best.0
    }

    static func words(_ text: String) -> [String] {
        TopicKey.fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

// MARK: - Words

enum MaterialText {
    /// "Book", "Paper".
    static func kind(_ kind: MaterialClassifier.Kind) -> String {
        kind == .paper ? String(localized: "Paper") : String(localized: "Book")
    }

    /// "640 pages", "1 page".
    static func pages(_ count: Int) -> String {
        count == 1 ? String(localized: "1 page") : String(localized: "\(count) pages")
    }
}

// MARK: - HUD

/// The HUD while a book or paper is dragged (mockup 39): the course, "Materials · Book", the
/// page count and Change… (where to drop for another place: the toast's menu).
struct MaterialHUD: View {
    let prediction: MaterialPrediction

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let course = prediction.course {
                CourseHeader(course: course, font: DropHUD.titleFont)
            }
            Text(verbatim: String(localized: "Materials") + " · " + MaterialText.kind(prediction.kind))
                .font(.body)
                .lineLimit(1)
                .padding(.leading, prediction.course == nil ? 0 : 16)
            HStack(spacing: 8) {
                Text(MaterialText.pages(prediction.pageCount))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Change…")
                    .filingSmallButtonChrome()
            }
            .padding(.leading, prediction.course == nil ? 0 : 16)
            .padding(.top, 2)
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 12))
        .frame(width: DropHUD.width, alignment: .leading)
        .filingGlass()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toasts

/// The material toasts in the window's toast stack.
struct MaterialToastList: View {
    let handler: MaterialDropHandler
    let center: FilingCenter
    @State private var courses: [Course] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(handler.toasts) { toast in
                MaterialToastView(
                    toast: toast,
                    courses: courses,
                    undo: { Task { await handler.undo(toast.id) } },
                    materials: { course in Task { await handler.choose(toast.id, course: course) } },
                    slides: { course in Task { await handler.fileAsSlides(toast.id, course: course, center: center) } },
                    dismiss: { handler.dismiss(toast.id) }
                )
                .onHover { handler.setHovering(toast.id, $0) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: handler.toasts.map(\.id))
        .task(id: handler.toasts.count) {
            if !handler.toasts.isEmpty, courses.isEmpty { courses = (try? await center.service.courses()) ?? [] }
        }
    }
}

/// One dropped book or paper (mockup 39): the cover as the 38 pt tile, the course, "Book · 640
/// pages", Undo and Change… (each course: Materials, Slides). Without a course: the file's name
/// over "Book · 640 pages" and Change…; a failure: the triangle and the sentence.
struct MaterialToastView: View {
    let toast: MaterialDropHandler.Toast
    var courses: [Course] = []
    var undo: () -> Void = {}
    var materials: (Course) -> Void = { _ in }
    var slides: (Course) -> Void = { _ in }
    var dismiss: () -> Void = {}
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CoverTile(cover: toast.cover, failed: toast.failure != nil)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let course = toast.course, toast.failure == nil {
                        CourseHeader(course: course)
                    } else {
                        Text(verbatim: toast.fileName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let failure = toast.failure {
                        Text(verbatim: failure)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(verbatim: MaterialText.kind(toast.reading.kind) + " · " + MaterialText.pages(toast.reading.pageCount))
                            .font(.body)
                            .monospacedDigit()
                            .lineLimit(1)
                            .padding(.leading, toast.course == nil ? 0 : 16)
                    }
                }
                actions
            }
        }
        .padding(EdgeInsets(top: 13, leading: 12, bottom: 13, trailing: 14))
        .huggingWidth(upTo: FilingToastView.maximumWidth)
        .filingGlass()
        .overlay(alignment: .topLeading) {
            if isHovering, toast.course == nil || toast.failure != nil {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .accessibilityLabel(Text("Close"))
            }
        }
        .onHover { isHovering = $0 }
        .disabled(toast.isWorking)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if toast.material != nil {
                Button(action: undo) {
                    UndoLabel()
                }
                .buttonStyle(FilingSmallButtonStyle())
            }
            if toast.failure == nil || toast.material == nil {
                Menu {
                    ForEach(courses) { course in
                        Section {
                            Button {
                                materials(course)
                            } label: {
                                if course.id == toast.course?.id, toast.material != nil {
                                    Label("Materials", systemImage: "checkmark")
                                } else {
                                    Text("Materials")
                                }
                            }
                            Button("Slides") { slides(course) }
                        } header: {
                            Text(course.name)
                        }
                    }
                } label: {
                    Text("Change…")
                        .filingSmallButtonChrome(isHighlighted: toast.course == nil)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .fixedSize()
    }
}

/// The toast's 38 pt tile with the cover (22 wide, on white paper with a hairline), `book` while
/// it is drawn, or the triangle after a failure.
struct CoverTile: View {
    let cover: URL?
    var failed = false
    @State private var image: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape
            .fill(Self.window)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .frame(width: 38, height: 38)
            .overlay {
                if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.secondary)
                } else if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 31)
                        .background(Color.white)
                        .overlay(Rectangle().strokeBorder(.separator, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                } else {
                    Image(systemName: "book")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: cover) { image = cover.flatMap(Self.load) }
            .accessibilityHidden(true)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static var window: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
