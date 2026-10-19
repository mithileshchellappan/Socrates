import QuickLook
import StudyCore
import StudyUI
import SwiftUI

/// The Documents screen (docs/plan-docs.md §6; DESIGN 8.8 once written): the document list column
/// (260) | `Divider` | the reader with the file (Quick Look), the summary, key facts and dates.
/// Files dropped anywhere on it, or picked with Import…, are added (PDFs too: here they are
/// documents); new ones appear at the top, selected. Delete (the row's menu, ⌫) has Edit ▸ Undo
/// without a confirmation, as Notes. With nothing selected the newest opens. An empty bank is
/// one line and Import… over the whole detail, a drop target.
///
/// Reads rows itself (`@FetchAll`), writes only through `\.documentActions` (read-only by default:
/// the iPhone never shows it, it only compiles there), and publishes the selected document as the
/// agent panel's context.
public struct DocumentsView: View {
    @Binding var selection: StudyDocument.ID?
    /// The page a search hit or a `[[doc …]]` chip named.
    let page: Int?
    let launch: DocumentsLaunch

    @FetchAll(StudyDocument.order { $0.addedAt.desc() }) private var documents
    @FetchAll(Course.order { ($0.sortOrder, $0.name) }) private var courses
    @Environment(\.documentActions) private var actions
    @Environment(\.studyServices) private var services
    @Environment(\.undoManager) private var undoManager
    /// The window's smart import: files dropped on an empty bank that are not documents go there.
    @Environment(\.importFiles) private var smartImport
    @State private var showsImporter = false
    @State private var isDropTargeted = false
    @State private var quickLookURL: URL?
    /// A document just added: selected before its row arrives, so the newest does not take over.
    @State private var arriving: StudyDocument.ID?
    /// The document `page` belongs to (it opened with it); another selection shows no page.
    @State private var pageDocument: StudyDocument.ID?
    @State private var failure: String?
    @State private var undoTarget = DocumentsUndoTarget()
    @FocusState private var listFocused: Bool

    /// The list column's width (plan §6).
    static let listWidth: CGFloat = 260

    public init(selection: Binding<StudyDocument.ID?>, page: Int? = nil, launch: DocumentsLaunch = DocumentsLaunch()) {
        _selection = selection
        self.page = page
        self.launch = launch
    }

    private var now: Date { launch.now ?? Date() }

    private var selected: StudyDocument? {
        guard let selection else { return nil }
        return documents.first { $0.id == selection }
    }

    // MARK: Body

    public var body: some View {
        content
            .background(Color.contentBackground)
            .toolbar { toolbar }
            .screenTitle(String(localized: "Documents"))
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: StudyDocument.acceptedTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { add(urls) }
            }
            .quickLookPreview($quickLookURL)
            .onChange(of: quickLookURL) { old, _ in
                if let old { DocumentFiles.removePreview(old) }
            }
            .alert(String(localized: "Couldn’t finish"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: failure ?? "")
            }
            .agentContext(AgentContext(screen: .documents, documentID: selected?.id))
            .focusedSceneValue(\.documentsImport, actions.isEditable ? DocumentsImportAction { showsImporter = true } : nil)
            .onAppear { selectFirstIfNeeded() }
            .onChange(of: documents.map(\.id)) { _, ids in
                if let arriving, ids.contains(arriving) { self.arriving = nil }
                selectFirstIfNeeded()
            }
            .onChange(of: page, initial: true) { pageDocument = selection }
    }

    @ViewBuilder
    private var content: some View {
        if documents.isEmpty {
            // PRD "Empty screens invite the next action": one line and Import…, the whole detail a
            // drop target (EmptyDropPrompt's, routed to the bank; other files to smart import). It
            // rings only while a document is among the dragged files.
            EmptyDropPrompt(systemImage: "doc.on.doc", line: "Drop your documents here.", target: nil, accepts: DocumentFileTypes.isAccepted)
                .environment(\.importFiles, emptyImport)
        } else {
            HStack(spacing: 0) {
                listColumn
                    .frame(width: Self.listWidth)
                Divider()
                reader
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if isDropTargeted || launch.isDropTargeted { DocumentDropRing() }
                    }
            }
            .documentDropTarget(isEnabled: actions.isEditable, isTargeted: $isDropTargeted, drop: dropped)
        }
    }

    // MARK: List

    private var listColumn: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(documents) { document in
                    DocumentRow(document: document, now: now)
                        .tag(document.id)
                        .id(document.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .contextMenu(forSelectionType: StudyDocument.ID.self) { ids in
                menu(for: ids)
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard actions.isEditable, let selected else { return .ignored }
                delete(selected.id)
                return .handled
            }
            .onKeyPress(.space) {
                guard let selected else { return .ignored }
                toggleQuickLook(selected)
                return .handled
            }
            .onAppear { if let selection { proxy.scrollTo(selection) } }
            .onChange(of: selection) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<StudyDocument.ID>) -> some View {
        if let id = ids.first, ids.count == 1, let document = documents.first(where: { $0.id == id }) {
            Button("Quick Look") { openQuickLook(document) }
            if actions.isEditable {
                if DocumentState(document).isFailed {
                    Button("Read Again") { retry(id) }
                }
                Divider()
                Button("Delete") { delete(id) }
            }
        }
    }

    // MARK: Reader

    @ViewBuilder
    private var reader: some View {
        if let selected {
            DocumentReader(
                document: selected,
                courses: courses,
                page: pageDocument == selected.id ? page : nil,
                now: now,
                isEditable: actions.isEditable,
                quickLook: { openQuickLook(selected) },
                retry: { retry(selected.id) }
            )
            .id(selected.id)
        } else {
            Color.clear
        }
    }

    // MARK: Toolbar

    /// Import… in the toolbar once there is a list; an empty bank's own Import… is the prompt's
    /// (one button, not two).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if actions.isEditable, !documents.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsImporter = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .help(Text("Import…"))
            }
        }
    }

    // MARK: Actions

    /// Import… on an empty bank, and files dropped on it (documents to the bank, the rest to the
    /// window's smart import). Nil when read-only: no button.
    private var emptyImport: ImportFilesAction? {
        guard actions.isEditable else { return nil }
        return ImportFilesAction(
            open: { _ in showsImporter = true },
            drop: { urls, _ in dropped(urls) }
        )
    }

    /// Files dropped on the screen: documents are added; anything else goes to smart import.
    private func dropped(_ urls: [URL]) {
        let documentURLs = urls.filter(DocumentFileTypes.isAccepted)
        let others = urls.filter { !DocumentFileTypes.isAccepted($0) }
        if !others.isEmpty { smartImport?.drop(others, to: nil) }
        add(documentURLs)
    }

    /// Adds files; the first new (or already kept) document is selected (new rows appear at the top).
    private func add(_ urls: [URL]) {
        let urls = urls.filter(DocumentFileTypes.isAccepted)
        guard actions.isEditable, !urls.isEmpty else { return }
        let actions = actions
        Task {
            do {
                let ids = try await actions.add(urls)
                guard let first = ids.first else { return }
                if !documents.contains(where: { $0.id == first }) { arriving = first }
                selection = first
            } catch {
                DocumentsUILog.logger.error("Adding documents failed: \(String(describing: error), privacy: .private)")
                failure = (error as? LocalizedError)?.errorDescription ?? String(localized: "This file could not be added.")
            }
        }
    }

    private func retry(_ id: StudyDocument.ID) {
        guard actions.isEditable else { return }
        let actions = actions
        Task { await actions.retry(id) }
    }

    /// Delete (the menu, ⌫): no confirmation; Edit ▸ Undo puts it back (`DocumentsUndo`). The next
    /// document (else the one before) is selected.
    private func delete(_ id: StudyDocument.ID) {
        guard actions.isEditable, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        if selection == id {
            let next = documents.indices.contains(index + 1) ? documents[index + 1].id : (index > 0 ? documents[index - 1].id : nil)
            selection = next
        }
        if quickLookURL != nil { quickLookURL = nil }
        DocumentsUndo.delete(id, actions: actions, undoManager: undoManager, target: undoTarget, selection: $selection)
    }

    /// Like Notes: with nothing selected (or a document that is gone), the newest is open.
    private func selectFirstIfNeeded() {
        guard let first = documents.first else { return }
        if let selection, selection == arriving || documents.contains(where: { $0.id == selection }) { return }
        selection = first.id
    }

    private func openQuickLook(_ document: StudyDocument) {
        guard let services else { return }
        quickLookURL = DocumentFiles.previewURL(for: document, blobs: services.blobs)
    }

    /// Space: Quick Look opens on the selected document, and closes again.
    private func toggleQuickLook(_ document: StudyDocument) {
        if quickLookURL != nil {
            quickLookURL = nil
        } else {
            openQuickLook(document)
        }
    }
}

/// How the screen starts in the app's renders (`ParityMode`): a fixed "now" (the added days, the
/// dates' years) and the drop ring drawn as if accepted files were over it. The selection and the
/// page come in through `DocumentsView(selection:page:)`.
public struct DocumentsLaunch: Hashable, Sendable {
    public var now: Date?
    public var isDropTargeted: Bool

    public init(now: Date? = nil, isDropTargeted: Bool = false) {
        self.now = now
        self.isDropTargeted = isDropTargeted
    }
}

/// File ▸ Import… while Documents shows: opens the Documents importer (the app's File menu reads
/// it as `@FocusedValue(\.documentsImport)`; without it, smart import's panel).
public struct DocumentsImportAction {
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
    /// Set while the Documents screen shows and can add (the Mac).
    @Entry public var documentsImport: DocumentsImportAction?
}

/// The identity Delete's undo steps are registered with.
@MainActor
final class DocumentsUndoTarget {}

/// Delete with Edit ▸ Undo ("Undo Delete Document"), as Notes: Undo restores the rows (the bank
/// reads and summarises again what the delete stopped) and selects it; Redo deletes it again.
@MainActor
enum DocumentsUndo {
    static func delete(
        _ id: StudyDocument.ID, actions: DocumentActions, undoManager: UndoManager?, target: DocumentsUndoTarget,
        selection: Binding<StudyDocument.ID?>
    ) {
        let deleting = Task { () -> DocumentDeletion? in
            do {
                return try await actions.delete(id)
            } catch {
                DocumentsUILog.logger.error("Deleting a document failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard let undoManager else { return }
        let name = String(localized: "Delete Document")
        undoManager.registerUndo(withTarget: target) { target in
            let restoring = Task { () -> Bool in
                guard let deletion = await deleting.value else { return false }
                do {
                    try await actions.restore(deletion)
                    selection.wrappedValue = deletion.document.id
                    return true
                } catch {
                    DocumentsUILog.logger.error("Restoring a document failed: \(String(describing: error), privacy: .public)")
                    return false
                }
            }
            undoManager.registerUndo(withTarget: target) { target in
                Task {
                    guard await restoring.value else { return }
                    delete(id, actions: actions, undoManager: undoManager, target: target, selection: selection)
                }
            }
            undoManager.setActionName(name)
        }
        undoManager.setActionName(name)
    }
}

enum DocumentsUILog {
    static let logger = Log.logger(category: "documents-ui")
}
