import Filing
import Observation
import StudyCore
import StudyUI
import SwiftUI

// md (docs/plan-docs.md §5.2 step 4): files dropped on the window that smart import never takes
// (Word, OpenDocument, RTF, Pages, plain text, Markdown, images) go to the document bank, with a
// toast "Added to Documents" whose Undo deletes what the drop added (never a file kept before);
// it leaves after 8 s like a filed toast. PDFs stay with smart import (slides); on the Documents
// screen itself every accepted file, PDFs too, is a document (DocumentsUI's own drop). Smart
// import predicts nothing for these files (no evidence kind), so while only they are dragged the
// HUD stays away.

/// The window's way into the document bank (`FilingCenter.documents`, set by the app over its
/// `DocumentBank`; nil: such files are filed like any other and fail as neither slides nor a
/// recording).
@MainActor
@Observable
public final class DocumentDropHandler {
    /// Adds the files; returns only the documents this drop made new (`DocumentAddition.isNew`),
    /// so Undo never deletes a file that was kept before. Throws a readable sentence when none
    /// could be taken.
    public typealias Add = @MainActor @Sendable ([URL]) async throws -> [StudyDocument.ID]
    /// Undo from the toast: deletes those documents.
    public typealias Undo = @MainActor @Sendable ([StudyDocument.ID]) async -> Void

    /// One drop's toast.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        /// The dropped files' names.
        var fileNames: [String]
        /// The new documents (Undo deletes these); empty: all were kept already (no Undo).
        var documentIDs: [StudyDocument.ID]
        /// Why nothing was added (one readable sentence).
        var failure: String?
        var isWorking = false
    }

    @ObservationIgnored private let addDocuments: Add
    @ObservationIgnored private let deleteDocuments: Undo
    private(set) var toasts: [Toast] = []

    /// Seconds a toast stays (while not hovered), as a filed toast.
    @ObservationIgnored var toastLifetime: Duration = .seconds(8)
    static let maximumToasts = 3
    @ObservationIgnored private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var hovered: Set<UUID> = []

    public init(add: @escaping Add, undo: @escaping Undo) {
        addDocuments = add
        deleteDocuments = undo
    }

    /// Whether a dropped file goes to the bank: a type `StudyDocument` takes that smart import
    /// never does (not a PDF, not a timetable).
    public nonisolated static func takes(_ url: URL) -> Bool {
        guard url.isFileURL, !FilingTypes.isTimetable(url), let kind = StudyDocument.fileKind(forFileName: url.lastPathComponent) else {
            return false
        }
        return kind != .pdf
    }

    /// A window drop: its document files are added (a toast follows); returns the rest for smart
    /// import.
    func take(_ urls: [URL]) -> [URL] {
        let kept = urls.filter(Self.takes)
        guard !kept.isEmpty else { return urls }
        Task { await keep(kept) }
        return urls.filter { !Self.takes($0) }
    }

    private func keep(_ urls: [URL]) async {
        let names = urls.map(\.lastPathComponent)
        do {
            let ids = try await addDocuments(urls)
            show(Toast(fileNames: names, documentIDs: ids))
        } catch {
            FilingCenter.log.error("Adding dropped documents failed: \(String(describing: error), privacy: .private)")
            let sentence = (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn’t finish")
            show(Toast(fileNames: names, documentIDs: [], failure: sentence))
        }
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

    /// Undo: deletes the drop's new documents, then the toast goes.
    func undo(_ id: Toast.ID) async {
        guard let index = toasts.firstIndex(where: { $0.id == id }), !toasts[index].documentIDs.isEmpty else { return }
        toasts[index].isWorking = true
        dismissTasks.removeValue(forKey: id)?.cancel()
        await deleteDocuments(toasts[index].documentIDs)
        dismiss(id)
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

    private func scheduleDismissal(_ id: Toast.ID) {
        guard toasts.contains(where: { $0.id == id && !$0.isWorking }), !hovered.contains(id) else { return }
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
    public func preview(fileNames: [String], failure: String? = nil) {
        toasts.append(Toast(fileNames: fileNames, documentIDs: failure == nil ? [UUID()] : [], failure: failure))
    }
}

/// The document toasts in the window's toast stack (above the filed ones).
struct DocumentToastList: View {
    let handler: DocumentDropHandler

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(handler.toasts) { toast in
                DocumentToastView(
                    toast: toast,
                    undo: { Task { await handler.undo(toast.id) } },
                    dismiss: { handler.dismiss(toast.id) }
                )
                .onHover { handler.setHovering(toast.id, $0) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: handler.toasts.map(\.id))
    }
}

/// One drop into the bank (a filed toast's shape, mockup 10): the tile with `doc.on.doc`, "Added
/// to Documents" over the file's name (several: their names, shortened), and Undo. A failure: the
/// triangle, the file over the sentence, a close button on hover.
struct DocumentToastView: View {
    let toast: DocumentDropHandler.Toast
    var undo: () -> Void = {}
    var dismiss: () -> Void = {}
    @State private var isHovering = false

    private var names: String { toast.fileNames.joined(separator: ", ") }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DocumentToastTile(failed: toast.failure != nil)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let failure = toast.failure {
                        Text(verbatim: names)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: failure)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("Added to Documents")
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text(verbatim: names)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if toast.failure == nil, !toast.documentIDs.isEmpty {
                    Button(action: undo) {
                        UndoLabel()
                    }
                    .buttonStyle(FilingSmallButtonStyle())
                    .fixedSize()
                }
            }
        }
        .padding(EdgeInsets(top: 13, leading: 12, bottom: 13, trailing: 14))
        .huggingWidth(upTo: FilingToastView.maximumWidth)
        .filingGlass()
        .overlay(alignment: .topLeading) {
            if isHovering, toast.failure != nil {
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
}

/// The toast's 38 pt tile (`FileTile`'s look): the window colour, a hairline, `doc.on.doc` (the
/// Documents row's glyph), or the triangle after a failure.
private struct DocumentToastTile: View {
    let failed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape
            .fill(Self.window)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: failed ? "exclamationmark.triangle" : "doc.on.doc")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }

    private static var window: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
