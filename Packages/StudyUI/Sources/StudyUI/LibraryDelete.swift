import StudyCore
import SwiftUI

/// Delete… on a deck, a lecture or a recording: the window asks first (its confirmation names
/// what goes, the student's notes, ink and practice among it), then deletes with Edit ▸ Undo. The
/// app installs it (`.environment(\.deleteFromLibrary, …)`); nil: no Delete… items.
public struct DeleteFromLibraryAction: Sendable {
    private let handler: @MainActor @Sendable (StudyCore.LibraryItem) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (StudyCore.LibraryItem) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ item: StudyCore.LibraryItem) {
        handler(item)
    }
}

extension EnvironmentValues {
    @Entry public var deleteFromLibrary: DeleteFromLibraryAction?
}

/// What the focused screen has open, for Edit ▸ Delete Lecture… / Delete Slides… / Delete
/// Recording… (the open review; list rows are buttons, so the menu acts on the open lecture only).
public struct OpenLibraryItems {
    public var lecture: Lecture.ID?
    public var deck: Deck.ID?
    public var recording: Recording.ID?
    public var delete: DeleteFromLibraryAction

    public init(lecture: Lecture.ID?, deck: Deck.ID?, recording: Recording.ID?, delete: DeleteFromLibraryAction) {
        self.lecture = lecture
        self.deck = deck
        self.recording = recording
        self.delete = delete
    }
}

extension FocusedValues {
    @Entry public var openLibraryItems: OpenLibraryItems?
}
