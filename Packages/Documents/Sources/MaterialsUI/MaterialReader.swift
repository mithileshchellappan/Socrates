import DocumentsUI
import StudyCore
import StudyUI
import SwiftUI

/// A PDF material read in the app (mt, docs/plan-materials.md §2.3, mockup 37), pushed full width
/// on its course's Materials: the contents column (260) | `Divider` | the pages (`PDFReader`:
/// continuous, fit to the width up to 900 pt times the content zoom, white pages in both
/// appearances). The column: the cover, title and authors; the chapters with their printed first
/// page and the lectures that cover them ("L2 · L3", help their titles); the chapter in view is
/// selected and shows its ≤ 3-line summary (grey, one sparkle; written in the background the first
/// time it is current: a skeleton line meanwhile) and its sections. While the toolbar's field
/// ("Search book", the app's, passed in as `query`) holds a query, the column lists its hits
/// ("§6.2 · p. 214" under each snippet, ↩ the next) and the pages mark them in the highlighter.
/// Opening at a page (a chip, a hit, a reading) marks the passage's first words there until the
/// next click; otherwise the reader opens where the student was (`last_page`, written 2 s after
/// scrolling rests and on leaving). Ask About Selection (the pages' menu) opens the agent panel
/// with the passage as context. A material without sections has no column. Mac only.
public struct MaterialReader: View {
    private let materialID: CourseMaterial.ID
    private let page: Int?
    private let request: UUID?
    private let query: String
    private let submits: Int

    /// - Parameters:
    ///   - page: the 1-based PDF page to open at (nil: where the student was).
    ///   - request: set once per open request, so opening the same page again moves there again.
    ///   - query: the toolbar search field's text (`searchPrompt` names it).
    ///   - submits: counts ↩ in the field (the next hit).
    public init(materialID: CourseMaterial.ID, page: Int? = nil, request: UUID? = nil, query: String = "", submits: Int = 0) {
        self.materialID = materialID
        self.page = page
        self.request = request
        self.query = query
        self.submits = submits
    }

    /// The toolbar field's prompt for a material: "Search book", "Search paper", "Search document".
    public static func searchPrompt(_ kind: MaterialKind?) -> LocalizedStringKey {
        switch kind {
        case .book?: "Search book"
        case .paper?: "Search paper"
        default: "Search document"
        }
    }

    public var body: some View {
        #if os(macOS)
        MaterialReaderContent(materialID: materialID, page: page, request: request, query: query, submits: submits)
        #else
        ContentUnavailableView {
            Image(systemName: "book.closed")
        }
        #endif
    }
}

#if os(macOS)
private struct MaterialReaderContent: View {
    let materialID: CourseMaterial.ID
    let page: Int?
    let request: UUID?
    let query: String
    let submits: Int

    @Fetch private var data: MaterialReaderData
    @State private var model = PDFReaderModel()
    @State private var hits: [MaterialSearchHit] = []
    @State private var selectedHit: Int?
    @State private var passage = ReaderPassage()
    @State private var summarized: Set<MaterialSection.ID> = []
    @State private var opened = false
    @Environment(\.studyServices) private var services
    @Environment(\.openDestination) private var openDestination
    @Environment(\.openAgentPanel) private var openAgentPanel
    @Environment(\.materialReaderQueuesSummaries) private var queuesSummaries

    static let columnWidth: CGFloat = 260

    init(materialID: CourseMaterial.ID, page: Int?, request: UUID?, query: String, submits: Int) {
        self.materialID = materialID
        self.page = page
        self.request = request
        self.query = query
        self.submits = submits
        _data = Fetch(wrappedValue: .empty, MaterialReaderRequest(materialID: materialID))
    }

    var body: some View {
        HStack(spacing: 0) {
            if !data.sections.isEmpty || !query.isEmpty {
                MaterialContents(
                    data: data, page: model.page, query: query, hits: hits, selectedHit: selectedHit,
                    go: { model.go(to: $0) }, goHit: { index in show(hit: index) },
                    openNotes: { openDestination(.lectureNotes($0)) },
                    openReview: { openDestination(.lecture($0, ReviewTarget())) }
                )
                .frame(width: Self.columnWidth)
                Divider()
            }
            PDFReader(model: model, askAboutSelection: { text, page in ask(text, page: page) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.contentBackground)
        .screenTitle(String(localized: "Materials"), subtitle: data.course?.name ?? "")
        .contentZoomable()
        .transformPreference(AgentContextPreferenceKey.self) { [source = contextSource] value in
            value = source
        }
        .onChange(of: data.fileURL(services), initial: true) { _, url in
            guard let url else { return }
            model.load(url)
            openAtStart()
        }
        .onChange(of: request) { openAtStart(force: true) }
        .onChange(of: page) { openAtStart(force: true) }
        .onChange(of: model.page) { _, page in queueSummary(at: page) }
        .task(id: query) { await search() }
        .onChange(of: submits) { nextHit() }
        .onAppear {
            let repository = services.map { MaterialRepository(store: $0.records) }
            let id = materialID
            model.onRest = { page in
                Task { try? await repository?.setLastPage(id, page: page) }
            }
        }
        .onDisappear {
            guard let services, model.page > 0 else { return }
            let repository = MaterialRepository(store: services.records)
            let id = materialID
            let page = model.page
            Task { try? await repository.setLastPage(id, page: page) }
        }
    }

    // MARK: Opening

    /// At the page asked for (its passage's first words marked), else where the student was.
    private func openAtStart(force: Bool = false) {
        guard data.material != nil, force || !opened else { return }
        opened = true
        if let page {
            guard let services, let documentID = data.material?.documentID else {
                model.go(to: page)
                return
            }
            let model = model
            Task {
                let text = try? await MaterialSearch.pageText(documentID: documentID, page: page, database: services.database)
                model.go(to: page, mark: text.flatMap(MaterialSearch.firstWords))
            }
        } else if let last = data.material?.lastPage {
            model.go(to: last)
        } else {
            model.go(to: 1)
        }
    }

    // MARK: Summaries

    /// The first time a chapter is current and has no summary, its summary is queued (one
    /// background Haiku task; the column shows a skeleton line until it is written).
    private func queueSummary(at page: Int) {
        guard queuesSummaries, let services, let chapter = data.chapter(holding: page), chapter.summary.isEmpty,
              !summarized.contains(chapter.id)
        else { return }
        summarized.insert(chapter.id)
        let repository = MaterialRepository(store: services.records)
        let id = chapter.id
        Task {
            do {
                _ = try await repository.queueChapterSummary(id, by: .user)
            } catch {
                MaterialsUILog.logger.error("Queueing a chapter summary failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Search

    private func search() async {
        selectedHit = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let services, let documentID = data.material?.documentID else {
            hits = []
            model.mark(query: "", pages: [])
            return
        }
        // Typing settles first.
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        let found = (try? await MaterialSearch.hits(query: text, documentID: documentID, database: services.database)) ?? []
        guard !Task.isCancelled else { return }
        hits = found
        model.mark(query: text, pages: found.map(\.page))
    }

    private func show(hit index: Int) {
        guard hits.indices.contains(index) else { return }
        selectedHit = index
        model.go(to: hits[index].page, mark: hits[index].match)
    }

    /// ↩ in the field: the next hit.
    private func nextHit() {
        guard !hits.isEmpty else { return }
        show(hit: ((selectedHit ?? -1) + 1) % hits.count)
    }

    // MARK: The agent

    /// Ask About Selection: the passage goes with the next message as data; the panel opens.
    private func ask(_ text: String, page: Int) {
        passage.value = MaterialPassageContext(text: text, page: page)
        openAgentPanel(expanded: false)
    }

    /// The reader as the panel's context; with a passage, `refine` runs once, when a message
    /// reads it: the passage goes with that message only.
    private var contextSource: AgentContextSource {
        let context = AgentContext(
            screen: .course, courseID: data.material?.courseID, courseScreen: "materials", materialID: materialID,
            materialPage: model.page > 0 ? model.page : nil, materialPassage: passage.value
        )
        guard passage.value != nil else { return AgentContextSource(context: context) }
        let passage = passage
        return AgentContextSource(context: context) {
            Task { @MainActor in passage.value = nil }
            return AgentContext(screen: .course)
        }
    }
}

/// Ask About Selection's passage, until a message has taken it.
@MainActor
@Observable
private final class ReaderPassage {
    var value: MaterialPassageContext?
}
#endif

extension EnvironmentValues {
    /// The reader queues a chapter's summary the first time it is current (off in renders).
    @Entry public var materialReaderQueuesSummaries = true
}

// MARK: - Rows

/// The reader's rows in one observed read.
struct MaterialReaderData: Equatable, Sendable {
    struct LectureRef: Equatable, Sendable {
        var id: Lecture.ID
        var number: Int?
        var title: String
    }

    var material: CourseMaterial?
    var course: Course?
    var document: StudyDocument?
    var sections: [MaterialSection] = []
    var coverage: [MaterialCoverage] = []
    var lectures: [Lecture.ID: LectureRef] = [:]
    /// Chapters whose summary is being written (an open `material_chapter` task).
    var summarizing: Set<MaterialSection.ID> = []

    static let empty = MaterialReaderData()

    @MainActor
    func fileURL(_ services: StudyServices?) -> URL? {
        guard let services, let blob = document?.blob else { return nil }
        return services.blobs.url(for: blob)
    }

    /// The chapters and other top-level entries, in order.
    var chapters: [MaterialSection] { sections.filter { $0.level <= 1 } }

    func chapter(holding page: Int) -> MaterialSection? {
        chapters.filter { $0.contains(page: page) }.max { $0.firstPage < $1.firstPage }
    }

    func sections(of chapter: MaterialSection) -> [MaterialSection] {
        sections.filter { $0.level >= 2 && $0.chapter(in: sections)?.id == chapter.id }
    }

    /// The lectures that cover a chapter (it or one of its sections), by number: "L2 · L3".
    func lectures(covering chapter: MaterialSection) -> [LectureRef] {
        let ids = Set(sections(of: chapter).map(\.id) + [chapter.id])
        let covering = Set(coverage.filter { ids.contains($0.sectionID) }.map(\.lectureID))
        return covering.compactMap { lectures[$0] }.sorted { ($0.number ?? .max, $0.title) < ($1.number ?? .max, $1.title) }
    }
}

struct MaterialReaderRequest: FetchKeyRequest {
    let materialID: CourseMaterial.ID

    func fetch(_ db: Database) throws -> MaterialReaderData {
        var data = MaterialReaderData()
        guard let material = try CourseMaterial.find(materialID).fetchOne(db) else { return data }
        data.material = material
        data.course = try Course.find(material.courseID).fetchOne(db)
        if let documentID = material.documentID {
            data.document = try StudyDocument.find(documentID).fetchOne(db)
        }
        data.sections = try MaterialRepository.sections(of: materialID, in: db)
        let id = materialID
        data.coverage = MaterialCoverage.effective(try MaterialCoverage.where { $0.materialID.eq(id) }.fetchAll(db))
        let lectureIDs = Array(Set(data.coverage.map(\.lectureID)))
        if !lectureIDs.isEmpty {
            for lecture in try Lecture.where({ $0.id.in(lectureIDs) }).fetchAll(db) {
                data.lectures[lecture.id] = .init(id: lecture.id, number: lecture.number, title: lecture.title)
            }
        }
        if let documentID = material.documentID {
            let reference = StudyDocument.ID?.some(documentID)
            let goals = try AgentTask
                .where { $0.kind.eq(AgentTaskKind.materialChapter) && $0.documentID.eq(reference) && $0.state.in(AgentTaskState.open) }
                .select(\.goal)
                .fetchAll(db)
            data.summarizing = Set(goals.compactMap(MaterialSection.sectionID(fromTaskGoal:)))
        }
        return data
    }
}
