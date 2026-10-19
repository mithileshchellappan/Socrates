import StudyCore
import StudyUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// The Documents screen as a drop target (docs/plan-docs.md §6 "Drop and Import…"): files of
    /// `StudyDocument.acceptedTypes` (PDFs too: here a PDF is a document, never slides) set
    /// `isTargeted` while they hover and are handed to `drop`; a drag with none of them is refused
    /// (no ring), so the window's smart import keeps it. Mac only (the iPhone is read-only).
    func documentDropTarget(isEnabled: Bool, isTargeted: Binding<Bool>, drop: @escaping @MainActor ([URL]) -> Void) -> some View {
        modifier(DocumentDropTargetModifier(isEnabled: isEnabled, isTargeted: isTargeted, drop: drop))
    }
}

private struct DocumentDropTargetModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let drop: @MainActor ([URL]) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onDrop(of: [.fileURL], delegate: DocumentDropDelegate(isEnabled: isEnabled, isTargeted: $isTargeted, drop: drop))
        #else
        content
        #endif
    }
}

#if os(macOS)
/// Reads the drag pasteboard's file URLs directly (synchronously), so a drag of files the bank
/// does not take is refused before it lands.
@MainActor
private struct DocumentDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let drop: @MainActor ([URL]) -> Void

    private var fileURLs: [URL] {
        NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && fileURLs.contains(where: DocumentFileTypes.isAccepted)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .copy) : DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let urls = fileURLs
        guard isEnabled, urls.contains(where: DocumentFileTypes.isAccepted) else { return false }
        drop(urls)
        return true
    }
}
#endif

/// What the Documents screen takes: `StudyDocument.acceptedTypes`, by the file's extension.
enum DocumentFileTypes {
    static func isAccepted(_ url: URL) -> Bool {
        url.isFileURL && StudyDocument.fileKind(forFileName: url.lastPathComponent) != nil
    }
}

/// The accent ring while accepted files hover (as `EmptyDropPrompt`'s): accent soft with a
/// 1.5 pt accent border, 12 in from the reader's edges.
struct DocumentDropRing: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape
            .fill(Color.accentSoft(colorScheme))
            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1.5))
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
