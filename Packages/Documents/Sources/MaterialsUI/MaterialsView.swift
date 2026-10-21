import DocumentsUI
import QuickLook
import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

/// A course's Materials (mt, docs/plan-materials.md §2.2, mockups 36 and 39), between Slides and
/// Notes: one scroll view in Lectures' 760 pt column, at most three zones 28 pt apart (a zone
/// without items is absent): Books as cover tiles, Papers and references as rows, Links as rows.
/// No filled button: the first cover is the obvious first thing. Click or ↩ opens (a PDF the
/// reader, a link the browser, another file Quick Look); Space Quick Look; ⌫ deletes without a
/// confirmation (Edit ▸ Undo "Delete Material"); the context menu has the rest. The whole screen
/// takes PDFs, the bank's other files, URLs and `.webloc` files (the accent ring only while such
/// items hover); ⌘V pastes copied files or a URL; [Import +] and File ▸ Import… pick files. New
/// items appear in their zone (no toast here). Empty: one line and Import… over the whole detail.
///
/// Reads rows itself (`@Fetch`), writes only through `\.materialLibrary` (nil: read-only, the
/// iPhone), and publishes the course (and the focused material) as the agent panel's context.
public struct MaterialsView: View {
    private let courseID: Course.ID
    private let launch: MaterialsLaunch
    @Fetch private var shelf: MaterialShelfData
    @Environment(\.materialLibrary) private var library
    @Environment(\.studyServices) private var services
    @Environment(\.openDestination) private var openDestination
    @Environment(\.openURL) private var openURL
    @Environment(\.undoManager) private var undoManager
    @State private var showsImporter = false
    @State private var isDropTargeted = false
    @State private var quickLookURL: URL?
    @State private var failure: String?
    @State private var undoTarget = MaterialsUndoTarget()
    @FocusState private var focus: CourseMaterial.ID?

    /// Lectures' column (DESIGN 6.1).
    static let columnWidth: CGFloat = 760

    public init(courseID: Course.ID, launch: MaterialsLaunch = MaterialsLaunch()) {
        self.courseID = courseID
        self.launch = launch
        _shelf = Fetch(wrappedValue: .empty, MaterialShelfRequest(courseID: courseID))
    }

    private var isEditable: Bool { library != nil }

    public var body: some View {
        content
            .background(Color.contentBackground)
            .screenTitle(String(localized: "Materials"), subtitle: shelf.course?.name ?? "")
            .toolbar { toolbar }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: MaterialDrop.importTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { add(files: urls) }
            }
            #if os(macOS)
            .quickLookPreview($quickLookURL)
            .onChange(of: quickLookURL) { old, _ in
                if let old { DocumentFiles.removePreview(old) }
            }
            #endif
            .alert(String(localized: "Couldn’t finish"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: failure ?? "")
            }
            .agentContext(AgentContext(screen: .course, courseID: courseID, courseScreen: "materials", materialID: focus))
            .focusedSceneValue(\.materialsImport, isEditable ? MaterialsImportAction { showsImporter = true } : nil)
    }

    @ViewBuilder
    private var content: some View {
        if shelf.isLoaded, shelf.materials.isEmpty {
            // PRD "Empty screens invite the next action": the whole detail takes the drop.
            EmptyDropPrompt(systemImage: "book.closed", line: "Drop books, papers and links here.", target: .course(courseID), accepts: MaterialDrop.isAcceptedFile)
                .environment(\.importFiles, emptyImport)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !books.isEmpty {
                        zone("Books") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 18) {
                                ForEach(books) { material in
                                    item(material) {
                                        BookTile(material: material, document: shelf.document(of: material), chapters: shelf.chapters[material.id] ?? 0, fill: fill)
                                    }
                                }
                            }
                        }
                    }
                    if !papers.isEmpty {
                        zone("Papers and references") {
                            rows(papers)
                        }
                    }
                    if !links.isEmpty {
                        zone("Links") {
                            rows(links)
                        }
                    }
                }
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 22)
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if isDropTargeted || launch.isDropTargeted { DocumentDropRing() }
            }
            .materialDropTarget(isEnabled: isEditable, isTargeted: $isDropTargeted, drop: dropped)
            #if os(macOS)
            .onPasteCommand(of: [.fileURL, .url, .plainText]) { _ in paste() }
            #endif
        }
    }

    // MARK: Zones

    private var books: [CourseMaterial] { shelf.materials.filter { $0.kind == .book } }
    private var papers: [CourseMaterial] { shelf.materials.filter { $0.kind == .paper || $0.kind == .reference } }
    private var links: [CourseMaterial] { shelf.materials.filter(\.kind.isLink) }

    /// A zone: its label (15 semibold, Study's zone labels) 10 above its items.
    private func zone(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.08)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func rows(_ materials: [CourseMaterial]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(materials.enumerated()), id: \.element.id) { index, material in
                item(material) {
                    MaterialRow(material: material, document: shelf.document(of: material), showsHairline: index > 0)
                }
            }
        }
        .padding(.horizontal, -8)
    }

    /// A tile or row: focusable (↩ opens, Space Quick Look, ⌫ deletes), a click opens, its menu.
    private func item(_ material: CourseMaterial, @ViewBuilder label: () -> some View) -> some View {
        label()
            .contentShape(Rectangle())
            .onTapGesture { open(material) }
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused($focus, equals: material.id)
            .onKeyPress(.return) {
                open(material)
                return .handled
            }
            .onKeyPress(.space) {
                guard material.kind.isFile else { return .ignored }
                toggleQuickLook(material)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard isEditable else { return .ignored }
                delete(material.id)
                return .handled
            }
            .contextMenu { menu(for: material) }
            .modifier(WantedDrop(material: material, isEnabled: isEditable, fill: fill))
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func menu(for material: CourseMaterial) -> some View {
        if material.state != .wanted {
            Button("Open") { open(material) }
        }
        if material.kind.isFile, shelf.document(of: material) != nil {
            Button("Quick Look") { openQuickLook(material) }
        }
        if material.kind.isLink, let url = material.url {
            Button("Open in Browser") { openURL(url) }
            Button("Copy Link") { MaterialPasteboard.copy(url.absoluteString) }
        }
        if isEditable {
            if material.kind.isLink, material.state != .pending {
                Button("Refresh") { readAgain(material.id) }
            }
            if material.kind.isFile, material.state != .wanted {
                Menu("Show As") {
                    ForEach(MaterialKind.files, id: \.self) { kind in
                        Toggle(MaterialsText.kindName(kind), isOn: Binding(get: { material.kind == kind }, set: { if $0 { setKind(kind, of: material.id) } }))
                    }
                }
            }
            if material.kind.isFile, material.state == .failed {
                Button("Read Again") { readAgain(material.id) }
            }
            Divider()
            Button("Delete") { delete(material.id) }
        }
    }

    // MARK: Toolbar

    /// [Import +] trailing, as Lectures and Slides (DESIGN 6.3).
    /// An empty shelf's own Import… is the prompt's (one button, not two).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isEditable, !shelf.materials.isEmpty {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Import", systemImage: "plus") { showsImporter = true }
                    .labelStyle(.titleAndIcon)
                    .help(Text("Import…"))
            }
        }
    }

    // MARK: Opening

    /// A PDF opens in the reader (pushed full width), a link in the browser, another file in
    /// Quick Look; a wanted book waits for its PDF.
    private func open(_ material: CourseMaterial) {
        focus = material.id
        switch MaterialOpening.how(material, document: shelf.document(of: material)) {
        case .reader: openDestination(.material(material.id, page: nil))
        case .browser(let url): openURL(url)
        case .quickLook: openQuickLook(material)
        case .nothing: break
        }
    }

    private func openQuickLook(_ material: CourseMaterial) {
        #if os(macOS)
        guard let services, let document = shelf.document(of: material) else { return }
        quickLookURL = DocumentFiles.previewURL(for: document, blobs: services.blobs)
        #endif
    }

    private func toggleQuickLook(_ material: CourseMaterial) {
        if quickLookURL != nil {
            quickLookURL = nil
        } else {
            openQuickLook(material)
        }
    }

    // MARK: Adding

    /// Import… and drops on the empty screen.
    private var emptyImport: ImportFilesAction? {
        guard isEditable else { return nil }
        return ImportFilesAction(
            open: { _ in showsImporter = true },
            drop: { urls, _ in dropped(urls) }
        )
    }

    /// Files, `.webloc` files and URLs dropped on the screen.
    private func dropped(_ urls: [URL]) {
        let items = MaterialDrop.items(urls)
        if !items.files.isEmpty { add(files: items.files) }
        for link in items.links { add(link: link) }
    }

    /// ⌘V: copied files, a copied URL, or text that is one URL.
    private func paste() {
        #if os(macOS)
        dropped(MaterialPasteboard.urls())
        #endif
    }

    private func add(files: [URL]) {
        guard let library, !files.isEmpty else { return }
        let courseID = courseID
        perform { _ = try await library.add(files: files, to: courseID, as: nil) }
    }

    private func add(link: URL) {
        guard let library else { return }
        let courseID = courseID
        perform { _ = try await library.add(link: link, to: courseID) }
    }

    private func setKind(_ kind: MaterialKind, of id: CourseMaterial.ID) {
        guard let library else { return }
        perform { try await library.setKind(kind, of: id) }
    }

    private func readAgain(_ id: CourseMaterial.ID) {
        guard let library else { return }
        perform { try await library.readAgain(id) }
    }

    /// Delete (⌫, the menu): no confirmation; Edit ▸ Undo "Delete Material" puts it back.
    private func delete(_ id: CourseMaterial.ID) {
        guard let library else { return }
        if quickLookURL != nil { quickLookURL = nil }
        if focus == id { focus = nil }
        MaterialsUndo.delete([id], library: library, undoManager: undoManager, target: undoTarget)
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
            } catch {
                MaterialsUILog.logger.error("A materials action failed: \(String(describing: error), privacy: .private)")
                failure = (error as? LocalizedError)?.errorDescription ?? String(localized: "This could not be added.")
            }
        }
    }

    /// A PDF dropped on a wanted book's cover fills it.
    private var fill: (CourseMaterial.ID, URL) -> Void {
        { id, url in
            guard let library else { return }
            perform { _ = try await library.fill(id, with: url) }
        }
    }
}

/// How the screen starts in renders: the drop ring drawn as if accepted files were over it.
public struct MaterialsLaunch: Hashable, Sendable {
    public var isDropTargeted: Bool

    public init(isDropTargeted: Bool = false) {
        self.isDropTargeted = isDropTargeted
    }
}

/// How a material opens (docs/plan-materials.md §2.1): a PDF in the reader, a link in the
/// browser, another file in Quick Look; a wanted book (no file yet) not at all.
public enum MaterialOpening: Equatable {
    case reader
    case browser(URL)
    case quickLook
    case nothing

    public static func how(_ material: CourseMaterial, document: StudyDocument?) -> MaterialOpening {
        if material.kind.isLink {
            return material.url.map { .browser($0) } ?? .nothing
        }
        guard material.state != .wanted else { return .nothing }
        if let document, document.fileType != UTType.pdf.identifier, document.fileType != "com.adobe.pdf" {
            return .quickLook
        }
        return .reader
    }
}

/// File ▸ Import… while Materials shows (the app's File menu reads `@FocusedValue(\.materialsImport)`).
public struct MaterialsImportAction {
    private let handler: @MainActor () -> Void

    public init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction() {
        handler()
    }
}

extension FocusedValues {
    /// Set while a course's Materials shows and can add (the Mac).
    @Entry public var materialsImport: MaterialsImportAction?
}

/// The identity Delete's undo steps are registered with.
@MainActor
final class MaterialsUndoTarget {}

/// Delete with Edit ▸ Undo "Delete Material" (as Documents): Undo restores every row and file the
/// delete took; Redo deletes again.
@MainActor
enum MaterialsUndo {
    static func delete(_ ids: [CourseMaterial.ID], library: any MaterialLibraryActions, undoManager: UndoManager?, target: MaterialsUndoTarget) {
        let deleting = Task { () -> MaterialDeletion? in
            do {
                return try await library.delete(ids)
            } catch {
                MaterialsUILog.logger.error("Deleting a material failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard let undoManager else { return }
        let name = String(localized: "Delete Material")
        undoManager.registerUndo(withTarget: target) { target in
            let restoring = Task { () -> Bool in
                guard let deletion = await deleting.value, !deletion.isEmpty else { return false }
                do {
                    try await library.restore(deletion)
                    return true
                } catch {
                    MaterialsUILog.logger.error("Restoring a material failed: \(String(describing: error), privacy: .public)")
                    return false
                }
            }
            undoManager.registerUndo(withTarget: target) { target in
                Task {
                    guard await restoring.value else { return }
                    delete(ids, library: library, undoManager: undoManager, target: target)
                }
            }
            undoManager.setActionName(name)
        }
        undoManager.setActionName(name)
    }
}

enum MaterialsUILog {
    static let logger = Log.logger(category: "materials-ui")
}

// MARK: - Rows

/// The shelf's rows in one observed read: the course, its materials in shelf order, their
/// documents (Mac only: a synced material may have none here) and each file's chapter count.
public struct MaterialShelfData: Equatable, Sendable {
    public var course: Course?
    public var materials: [CourseMaterial] = []
    public var documents: [StudyDocument.ID: StudyDocument] = [:]
    public var chapters: [CourseMaterial.ID: Int] = [:]
    public var isLoaded = false

    public static let empty = MaterialShelfData()

    func document(of material: CourseMaterial) -> StudyDocument? {
        material.documentID.flatMap { documents[$0] }
    }
}

struct MaterialShelfRequest: FetchKeyRequest {
    let courseID: Course.ID

    func fetch(_ db: Database) throws -> MaterialShelfData {
        var data = MaterialShelfData(isLoaded: true)
        data.course = try Course.find(courseID).fetchOne(db)
        data.materials = try MaterialRepository.materials(of: courseID, in: db)
        let documentIDs = data.materials.compactMap(\.documentID)
        if !documentIDs.isEmpty {
            for document in try StudyDocument.where({ $0.id.in(documentIDs) }).fetchAll(db) {
                data.documents[document.id] = document
            }
        }
        let ids = data.materials.map(\.id)
        if !ids.isEmpty {
            let chapters = try MaterialSection.where { $0.materialID.in(ids) && $0.level.eq(1) && $0.kind.eq(MaterialSectionKind.chapter) }
                .select(\.materialID)
                .fetchAll(db)
            for id in chapters { data.chapters[id, default: 0] += 1 }
        }
        return data
    }
}

/// The words of the shelf.
enum MaterialsText {
    static func kindName(_ kind: MaterialKind) -> String {
        switch kind {
        case .book: String(localized: "Book")
        case .paper: String(localized: "Paper")
        case .reference: String(localized: "Reference")
        case .repository: String(localized: "Repository")
        default: String(localized: "Website")
        }
    }

    /// "640 pages": the number in SF Mono.
    static func count(_ number: Int, one: String, many: String) -> Text {
        Text("\(Text(verbatim: "\(number)").font(.mono(11.5))) \(number == 1 ? one : many)")
    }

    /// "A. Sample · 2024".
    static func byline(_ material: CourseMaterial) -> String {
        [material.byline, material.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
