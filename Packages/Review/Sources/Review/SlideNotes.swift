import Foundation
import Observation
import StudyCore

/// Plain text ↔ note blocks for the M1 per-slide editor: one block per line; lines starting
/// `- [ ] ` or `- [x] ` are checklist items, everything else is a paragraph.
///
/// Only notes made of plain paragraph and checklist blocks (no rich runs, no attachments, no
/// other block types) are edited as text; anything else (written by a later notes editor) is
/// shown, never rewritten, so nothing is dropped. When text is turned back into blocks, lines
/// that did not change keep their block as it was, and edited lines keep the block's other
/// fields (level, source).
public enum NoteText {
    static let unchecked = "- [ ] "
    static let checked = "- [x] "

    /// True when the M1 text editor can edit these blocks without losing anything.
    public static func isEditable(_ blocks: [NoteBlock]) -> Bool {
        blocks.allSatisfy { block in
            (block.type == .paragraph || block.type == .checklist)
                && block.inlines == nil && block.attachment == nil
        }
    }

    /// The editor text of `blocks`.
    public static func text(of blocks: [NoteBlock]) -> String {
        blocks.map(line(for:)).joined(separator: "\n")
    }

    public static func line(for block: NoteBlock) -> String {
        guard block.type == .checklist else { return block.text }
        return (block.checked == true ? checked : unchecked) + block.text
    }

    /// The block one line of text stands for.
    public static func block(for line: String) -> NoteBlock {
        if line.hasPrefix(unchecked) {
            return .checklist(String(line.dropFirst(unchecked.count)), checked: false)
        }
        if line.hasPrefix(checked) || line.hasPrefix("- [X] ") {
            return .checklist(String(line.dropFirst(checked.count)), checked: true)
        }
        return .paragraph(line)
    }

    /// Blocks for `text`, reusing `previous` blocks for unchanged lines and carrying the other
    /// fields of an edited line's block over.
    public static func blocks(from text: String, previous: [NoteBlock] = []) -> [NoteBlock] {
        let newLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let oldLines = previous.map(line(for:))
        guard !previous.isEmpty else { return newLines.map(block(for:)) }

        // Old index for each unchanged new line, from the line diff.
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }
        let keptOld = oldLines.indices.filter { !removedOffsets.contains($0) }
        let keptNew = newLines.indices.filter { !insertedOffsets.contains($0) }
        var oldIndexForNew: [Int: Int] = [:]
        for (new, old) in zip(keptNew, keptOld) { oldIndexForNew[new] = old }

        // An inserted line that takes the place of a removed one is an edit of it.
        let removedInOrder = removedOffsets.sorted()
        let insertedInOrder = insertedOffsets.sorted()
        var editedFrom: [Int: Int] = [:]
        for (new, old) in zip(insertedInOrder, removedInOrder) { editedFrom[new] = old }

        return newLines.indices.map { index in
            if let old = oldIndexForNew[index] { return previous[old] }
            let fresh = block(for: newLines[index])
            guard let old = editedFrom[index] else { return fresh }
            var block = previous[old]
            block.type = fresh.type
            block.text = fresh.text
            block.checked = fresh.checked
            return block
        }
    }
}

/// Where a slide's notes are anchored.
public struct NoteAnchor: Sendable, Hashable {
    public var courseID: Course.ID?
    public var lectureID: Lecture.ID
    public var deckID: Deck.ID?
    public var page: Int
    public var recordingID: Recording.ID?

    public init(courseID: Course.ID?, lectureID: Lecture.ID, deckID: Deck.ID?, page: Int, recordingID: Recording.ID?) {
        self.courseID = courseID
        self.lectureID = lectureID
        self.deckID = deckID
        self.page = page
        self.recordingID = recordingID
    }
}

/// One note being edited in the inspector.
@MainActor
@Observable
public final class NoteDraft: Identifiable {
    public let id: Note.ID
    public private(set) var text: String
    /// False for notes with content the plain editor cannot represent; they are shown as text.
    public let isEditable: Bool
    /// The note as last written (nil until the first keystroke created it).
    public private(set) var note: Note?
    /// Seconds on the recording clock the note is anchored to.
    public var audioTime: Double? { note?.audioTime }

    init(note: Note?, id: Note.ID = UUID()) {
        self.id = note?.id ?? id
        self.note = note
        let blocks = note?.blocks ?? []
        isEditable = NoteText.isEditable(blocks)
        text = NoteText.isEditable(blocks) ? NoteText.text(of: blocks) : NoteBlock.plainText(of: blocks)
    }

    fileprivate func set(text: String, note: Note?) {
        self.text = text
        self.note = note
    }
}

/// The notes of one slide: every note anchored to (lecture, deck, page) as an editable draft
/// (live quick notes included), or one empty draft that becomes a note on its first keystroke,
/// anchored to the recording and the playhead at that moment. Edits are saved after a pause in
/// typing (`debounce`) through `NoteRepository.saveOrDeleteIfBlank`, so a note emptied out is
/// deleted.
@MainActor
@Observable
public final class SlideNoteEditor {
    public let anchor: NoteAnchor
    public private(set) var drafts: [NoteDraft]

    @ObservationIgnored private let repository: NoteRepository
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let playhead: () -> Double?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pending: [Note.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    /// `notes`: the slide's notes as fetched; `playhead`: the player's time for new notes.
    public init(
        anchor: NoteAnchor,
        notes: [Note],
        store: RecordStore,
        debounce: Duration = .milliseconds(500),
        now: @escaping () -> Date = { Date() },
        playhead: @escaping () -> Double?
    ) {
        self.anchor = anchor
        repository = NoteRepository(store: store)
        self.debounce = debounce
        self.playhead = playhead
        self.now = now
        let existing = notes.filter { $0.lectureID == anchor.lectureID && $0.pageNumber == anchor.page }
        drafts = existing.isEmpty ? [NoteDraft(note: nil)] : existing.map { NoteDraft(note: $0) }
    }

    /// True when some draft has text.
    public var hasNotes: Bool {
        drafts.contains { !$0.text.allSatisfy(\.isWhitespace) }
    }

    /// Applies an edit; the note is created on the first keystroke and saved after `debounce`.
    public func setText(_ text: String, for draftID: Note.ID) {
        guard let draft = drafts.first(where: { $0.id == draftID }), draft.isEditable, text != draft.text else { return }
        var note = draft.note ?? Note(
            id: draft.id, courseID: anchor.courseID, lectureID: anchor.lectureID, deckID: anchor.deckID,
            pageNumber: anchor.page, recordingID: anchor.recordingID, audioTime: playhead(), createdAt: now()
        )
        note.blocks = NoteText.blocks(from: text, previous: draft.note?.blocks ?? [])
        draft.set(text: text, note: note)
        schedule(draft.id)
    }

    /// Writes every pending edit now (page change, closing the screen).
    public func flush() async {
        let ids = Array(pending.keys)
        for id in ids {
            pending[id]?.cancel()
            pending[id] = nil
            write(id)
        }
        await lastWrite?.value
    }

    // MARK: - Private

    private func schedule(_ id: Note.ID) {
        pending[id]?.cancel()
        let debounce = debounce
        // Holds the editor until the write is queued, so closing the slide never loses an edit.
        pending[id] = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.pending[id] = nil
            self.write(id)
        }
    }

    /// Queues the draft's current note for writing; writes run one after another.
    private func write(_ id: Note.ID) {
        guard let note = drafts.first(where: { $0.id == id })?.note else { return }
        let previous = lastWrite
        let repository = repository
        lastWrite = Task {
            await previous?.value
            do {
                try await repository.saveOrDeleteIfBlank(note)
            } catch {
                ReviewLog.logger.error("Saving a note failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
