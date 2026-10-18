import Notes
import StudyCore
import StudyUI
import SwiftUI

/// The Notes screen (mockup 04, DESIGN 8.4): the note list column (236 pt) | the editor, for All
/// Notes or one course. The app passes the selection (kept per window, set by
/// `StudyDestination.notes(_, note:)`) and the toolbar search field's text, which filters the list
/// in place ("Search notes").
///
/// M6 contract (docs/plan-m6.md §3): the signature is fixed; workstream A builds the screen.
public struct NotesView: View {
    private let scope: NotesScope
    @Binding private var selection: Note.ID?
    private let query: String

    public init(scope: NotesScope, selection: Binding<Note.ID?>, query: String = "") {
        self.scope = scope
        _selection = selection
        self.query = query
    }

    public var body: some View {
        ContentUnavailableView {
            Image(systemName: "doc.text")
        }
    }
}
