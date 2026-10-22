#if os(macOS)
import Foundation
import StudyCore

/// What Your notes lists, prepared from its rows and the page's sections whenever one of them
/// changes (the column's `onChange`, never its `body`): the lecture's own notes, then one group
/// per slide with a note or ink in deck order, or (a lecture without a deck) one per note with a
/// moment, in time order.
struct YourNotesGroups {
    /// One group: a slide's notes and ink, or (a lecture without a deck) one note at its moment.
    struct Item: Identifiable, Equatable {
        let id: String
        var page: Int?
        var time: Double?
        var notes: [Note]
        var ink: InkDrawing?
        /// The section it belongs to (§4.4).
        var section: String?
        /// Changes when the group is to be drawn again (a note added, edited or deleted elsewhere).
        let key: String

        init(id: String, page: Int? = nil, time: Double? = nil, notes: [Note], ink: InkDrawing? = nil, section: String?) {
            self.id = id
            self.page = page
            self.time = time
            self.notes = notes
            self.ink = ink
            self.section = section
            key = id + "|" + YourNotesGroups.stamp(notes)
        }

        /// The group is one of those `follow` marks.
        func isFollowed(by follow: YourNotesFollow) -> Bool {
            switch follow {
            case .section(let key?): section == key
            case .page(let page?): self.page == page
            case .section(nil), .page(nil): false
            }
        }
    }

    /// What the groups are made from.
    struct Source: Equatable {
        var rows: YourNotesRows
        var sections: [LectureNotesSection]
        /// The pages whose group stays while one of its notes is typed in (emptied, its note is
        /// deleted on save).
        var keptPages: Set<Int>
        /// The notes typed in the lecture's own note since the typing started: without a deck one
        /// with a moment lists by it, but not before the typing ends (it would show twice).
        var typedInOwn: Set<Note.ID>
        /// Bumped when the typing in the own note ends without a deck: it is drawn again without
        /// the notes that now list by their moment.
        var ownGeneration: Int
    }

    /// Made from loaded rows (nothing is listed before).
    private(set) var isLoaded = false
    /// The lecture's own notes: the notes without a slide (with a deck), or without a slide and a
    /// moment (without one: the timed notes list by time).
    private(set) var ownNotes: [Note] = []
    /// Changes when the own note is to be drawn again.
    private(set) var ownKey = ""
    private(set) var items: [Item] = []

    init() {}

    init(_ source: Source) {
        let rows = source.rows
        isLoaded = rows.isLoaded
        ownNotes = rows.notes.filter { $0.pageNumber == nil && (rows.deck != nil || $0.audioTime == nil) }
        ownKey = "own\(source.ownGeneration)|" + Self.stamp(ownNotes)

        var byPage: [Int: [Note]] = [:]
        for note in rows.notes {
            if let page = note.pageNumber { byPage[page, default: []].append(note) }
        }
        let pages = Set(byPage.keys).union(rows.ink.keys).union(source.keptPages)
        items = pages.sorted().map { page in
            Item(
                id: "p\(page)", page: page, notes: (byPage[page] ?? []).sorted { $0.createdAt < $1.createdAt }, ink: rows.ink[page],
                section: LectureNotesSection.holding(page: page, in: source.sections)?.key
            )
        }
        if rows.deck == nil {
            let timed = rows.notes
                .filter { $0.pageNumber == nil && $0.audioTime != nil && !source.typedInOwn.contains($0.id) }
                .sorted { ($0.audioTime ?? 0) < ($1.audioTime ?? 0) }
            items += timed.map { note in
                Item(
                    id: "t\(note.id)", time: note.audioTime, notes: [note],
                    section: note.audioTime.flatMap { LectureNotesSection.holding(time: $0, recording: note.recordingID, in: source.sections)?.key }
                )
            }
        }
    }

    /// The one quiet fill under the groups `follow` marks, from the groups' laid-out frames; nil
    /// when none is marked or laid out.
    func run(following follow: YourNotesFollow, frames: [String: CGRect]) -> CGRect? {
        let marked = items.lazy.filter { $0.isFollowed(by: follow) }.compactMap { frames[$0.id] }
        guard let first = marked.first else { return nil }
        return marked.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func stamp(_ notes: [Note]) -> String {
        notes.map { "\($0.id)@\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: ",")
    }
}
#endif
