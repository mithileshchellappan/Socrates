import Foundation
import Observation
import os
import StudyCore

/// One note open in an editor: what it was loaded as, and its saving (docs/plan-m6.md §4).
///
/// - Nothing is written on open. The editor calls `edited()` on every change the student makes;
///   a new note (`init(id:store:create:)`) becomes a row on its first change (`create` is asked
///   then, so a slide note's moment is the playhead at that keystroke).
/// - The body is read from the editor (`contentProvider`) only when saving: 500 ms after the last
///   change and on `flush()` (leaving the note), so typing never re-encodes the whole note.
/// - Blocks the student did not change keep their JSON (`NoteBlocks.reconcile`); an unchanged
///   body is not written.
/// - The write updates only the body of the row as it is then (a Move To from the list keeps its
///   course and lecture) through `NoteRepository.saveOrDeleteIfBlank`, so a note emptied out is
///   deleted. Writes run one after another on the database's queue, not on the main actor.
@MainActor
@Observable
public final class NoteSession: Identifiable {
    public let id: Note.ID
    /// The row as last loaded or written; nil for a new note before its first change.
    public private(set) var note: Note?
    /// The body as last loaded or written.
    public private(set) var blocks: [NoteBlock]
    /// True once the student changed something that is not written yet.
    public private(set) var hasPendingChanges = false

    /// Reads the editor's current body; nil once the editor is gone. Set by the editor.
    @ObservationIgnored public var contentProvider: (@MainActor () -> [NoteBlock]?)?

    @ObservationIgnored private let repository: NoteRepository
    @ObservationIgnored private let store: RecordStore
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let create: (@MainActor (Note.ID) -> Note)?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    /// An existing note.
    public init(note: Note, store: RecordStore, debounce: Duration = .milliseconds(500)) {
        id = note.id
        self.note = note
        blocks = note.blocks
        self.store = store
        repository = NoteRepository(store: store)
        self.debounce = debounce
        create = nil
    }

    /// A note that does not exist yet: `create` makes its row (anchor, course, moment) on the
    /// student's first change.
    public init(id: Note.ID = UUID(), store: RecordStore, debounce: Duration = .milliseconds(500), create: @escaping @MainActor (Note.ID) -> Note) {
        self.id = id
        note = nil
        blocks = []
        self.store = store
        repository = NoteRepository(store: store)
        self.debounce = debounce
        self.create = create
    }

    /// True when the row does not exist yet.
    public var isNew: Bool { note == nil }

    /// The student changed the note: create it on the first change, save after a pause.
    public func edited() {
        guard !isDiscarded else { return }
        hasPendingChanges = true
        if note == nil, let create {
            var row = create(id)
            row.blocksJSON = "[]"
            note = row
            // The first keystroke makes the row at once (it shows in the list).
            schedule(after: .zero)
            return
        }
        schedule(after: debounce)
    }

    /// The editor is closing: its body is read now and written (in the background) if changed.
    public func saveNow() {
        pending?.cancel()
        pending = nil
        save()
    }

    /// Writes a pending change now (leaving the note, the screen going away).
    public func flush() async {
        pending?.cancel()
        pending = nil
        if hasPendingChanges { save() }
        await lastWrite?.value
    }

    /// The note is being deleted: nothing pending is written, and nothing from now on.
    public func discard() {
        pending?.cancel()
        pending = nil
        hasPendingChanges = false
        isDiscarded = true
    }

    @ObservationIgnored private var isDiscarded = false

    // MARK: - Private

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.save()
        }
    }

    /// Reads the editor's body and queues the write when it differs from the stored one.
    private func save() {
        guard hasPendingChanges, var row = note, let content = contentProvider?() else { return }
        hasPendingChanges = false
        let fresh = NoteBlocks.reconcile(content, previous: blocks)
        guard !NoteBlocks.sameContent(fresh, blocks) else { return }
        blocks = fresh
        row.blocks = fresh
        note = row
        let json = row.blocksJSON
        let template = row
        let repository = repository
        let store = store
        let previous = lastWrite
        lastWrite = Task { [weak self] in
            await previous?.value
            do {
                // Only the body changes: the row as it is now keeps its course, lecture and anchor.
                var current = try await store.fetch(Note.self, id: template.id) ?? template
                current.blocksJSON = json
                let saved = try await repository.saveOrDeleteIfBlank(current)
                if let saved, let self, self.note?.blocksJSON == json {
                    self.note = saved
                }
            } catch {
                NotesLog.logger.error("Saving a note failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// The notes modules' logger (`os.Logger`, category "notes").
public enum NotesLog {
    public static let logger = Log.logger(category: "notes")
}
