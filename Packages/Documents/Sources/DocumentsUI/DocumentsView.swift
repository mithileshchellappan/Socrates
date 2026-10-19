import Documents
import StudyCore
import StudyUI
import SwiftUI

/// The Documents screen (docs/plan-docs.md §6): the document list column (260) | the reader with
/// the file (Quick Look), the summary, key facts and dates; drop anywhere on it and Import…;
/// Delete with Undo; the empty state inviting a drop. Reads rows itself, writes through
/// `\.documentActions`, publishes the selected document as the agent's context.
///
/// Contract skeleton (md architect): workstream B builds it.
public struct DocumentsView: View {
    @Binding var selection: StudyDocument.ID?
    /// The page a search hit or a `[[doc …]]` chip named.
    let page: Int?

    public init(selection: Binding<StudyDocument.ID?>, page: Int? = nil) {
        _selection = selection
        self.page = page
    }

    public var body: some View {
        ContentUnavailableView("Documents", systemImage: "doc.on.doc")
    }
}
