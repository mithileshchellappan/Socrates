import Deadlines
import Foundation
import StudyCore

/// mt (docs/plan-materials.md §3.5): a passage of the course's book given to the notes writer or
/// the asker, as `<book_passage cite=… section=… pages=…>` (escaped, data).
struct NotesBookPassage: Hashable, Sendable {
    /// `[[mat 3f2a9c1e p231]]`: the only material marker the answer may keep.
    var cite: String
    /// "6.2 Logical clocks".
    var section: String
    /// "231–232" (PDF pages, as the marker names them).
    var pages: String
    var text: String
}

/// Picks book passages on device: for each section of the notes (a topic) the course book
/// sections the lecture covers (`material_coverage`, the student's word deciding) are searched
/// with the section's words; the best windows of a page are merged and cut to whole sentences.
/// Primary book first; never the whole book.
enum NotesBookPassages {
    /// The notes: ≤ 3 passages of ≤ 1,500 characters, at most one per section of the notes.
    static func pick(_ m: NotesMaterial, passages: any MaterialPassages, database: any DatabaseReader) async -> [NotesBookPassage] {
        guard let covered = try? await database.read({ db in try Covered.load(lectureID: m.lecture.id, in: db) }), !covered.isEmpty else {
            return []
        }
        var found: [(score: Double, primary: Bool, passage: NotesBookPassage, section: String)] = []
        for section in m.sections {
            let slides = m.slides.filter { slide in
                guard let first = section.firstPage else { return false }
                return slide.page >= first && slide.page <= (section.lastPage ?? first)
            }
            let words = ([section.title] + slides.map(\.title)).joined(separator: " ")
            let targets = covered.sections(for: section.title)
            guard let best = await best(words, targets: targets, courseID: m.lecture.courseID, passages: passages, limit: MaterialCalls.notesPassageCharacters) else {
                continue
            }
            found.append((best.score, best.primary, best.passage, section.key))
        }
        var chosen: [NotesBookPassage] = []
        var used: Set<String> = []
        for item in found.sorted(by: { ($0.primary ? 1 : 0, $0.score) > ($1.primary ? 1 : 0, $1.score) }) {
            guard chosen.count < MaterialCalls.notesPassages, used.insert(item.passage.cite).inserted else { continue }
            chosen.append(item.passage)
        }
        return chosen
    }

    /// How long Ask waits for its book passages before it answers without them (the student
    /// waits on it: never block on the index).
    static let askBudget: Duration = .milliseconds(500)

    /// Ask: ≤ 2 passages of ≤ 1,200 characters from the section's covered pages, searched with the
    /// selection's words: the covered sections at once, in their order (primary book, core
    /// first); what is not found within `askBudget` is left out.
    static func pick(
        selection: String, sectionTitle: String, lectureID: Lecture.ID, courseID: Course.ID, passages: any MaterialPassages,
        database: any DatabaseReader, budget: Duration = askBudget
    ) async -> [NotesBookPassage] {
        guard let covered = try? await database.read({ db in try Covered.load(lectureID: lectureID, in: db) }), !covered.isEmpty else {
            return []
        }
        let targets = covered.sections(for: sectionTitle, fallback: true)
        guard !targets.isEmpty else { return [] }
        let found = await withTaskGroup(of: (index: Int, passage: NotesBookPassage?)?.self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    let best = await Self.best(selection, targets: [target], courseID: courseID, passages: passages, limit: MaterialCalls.askPassageCharacters)
                    return (index, best?.passage)
                }
            }
            // The deadline: nil.
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            var found: [Int: NotesBookPassage] = [:]
            var remaining = targets.count
            while remaining > 0, let next = await group.next() {
                guard let next else { break }
                remaining -= 1
                if let passage = next.passage { found[next.index] = passage }
            }
            group.cancelAll()
            return found
        }
        var chosen: [NotesBookPassage] = []
        for index in targets.indices {
            guard chosen.count < MaterialCalls.askPassages else { break }
            if let passage = found[index], !chosen.contains(where: { $0.cite == passage.cite }) {
                chosen.append(passage)
            }
        }
        return chosen
    }

    /// The best passage among `targets`' pages for `words`.
    private static func best(
        _ words: String, targets: [Covered.Target], courseID: Course.ID, passages: any MaterialPassages, limit: Int
    ) async -> (score: Double, primary: Bool, passage: NotesBookPassage)? {
        var best: (score: Double, primary: Bool, passage: NotesBookPassage)?
        for target in targets {
            let query = MaterialPassageQuery(text: words, courseID: courseID, materialID: target.material.id, pages: [target.section.pages], limit: 4)
            guard let hits = try? await passages.search(query), let top = hits.first else { continue }
            // The top hit's page: its windows there merged, in page order.
            let windows = hits.filter { $0.page == top.page }.map(\.text)
            let text = sentences(merged(windows), limit: limit)
            guard text.count >= 80 else { continue }
            let label = [target.section.number, target.section.title].filter { !$0.isEmpty }.joined(separator: " ")
            let last = min(target.section.lastPage, top.page + 1)
            let passage = NotesBookPassage(
                cite: ChatCitation.material(target.material.id, page: top.page).marker, section: label,
                pages: last > top.page ? "\(top.page)–\(last)" : "\(top.page)", text: text
            )
            let primary = target.material.isPrimary
            if best == nil || (primary ? 1 : 0, top.score) > ((best?.primary ?? false) ? 1 : 0, best?.score ?? 0) {
                best = (top.score, primary, passage)
            }
        }
        return best
    }

    /// Windows of one page joined, overlaps removed (a window that is part of the text so far is
    /// left out).
    static func merged(_ windows: [String]) -> String {
        var text = ""
        for window in windows {
            let clean = PromptText.collapsed(window)
            if text.contains(clean) { continue }
            text += text.isEmpty ? clean : " " + clean
        }
        return text
    }

    /// From the first sentence start to the last full stop, at most `limit` characters.
    static func sentences(_ text: String, limit: Int) -> String {
        var body = Substring(text)
        if let first = body.firstIndex(where: { $0.isUppercase }), body.distance(from: body.startIndex, to: first) < 120 {
            body = body[first...]
        }
        var clipped = String(body.prefix(limit))
        if let end = clipped.lastIndex(where: { ".!?".contains($0) }), clipped.distance(from: clipped.startIndex, to: end) > 60 {
            clipped = String(clipped[...end])
        }
        return clipped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The lecture's covered sections (core first), by the topic they were matched for.
    struct Covered: Sendable {
        struct Target: Sendable {
            var material: CourseMaterial
            var section: MaterialSection
            var topic: String
            var isCore: Bool
        }

        var targets: [Target]
        var isEmpty: Bool { targets.isEmpty }

        static func load(lectureID: Lecture.ID, in db: Database) throws -> Covered {
            let rows = MaterialCoverage.effective(try MaterialCoverage.where { $0.lectureID.eq(lectureID) }.fetchAll(db))
            guard !rows.isEmpty else { return Covered(targets: []) }
            let materials = Dictionary(
                try CourseMaterial.where { $0.id.in(Array(Set(rows.map(\.materialID)))) }.fetchAll(db)
                    .filter { $0.kind.isFile && $0.state == .ready && $0.documentID != nil }
                    .map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let sections = Dictionary(
                try MaterialSection.where { $0.id.in(rows.map(\.sectionID)) }.fetchAll(db).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let targets = rows.compactMap { row -> Target? in
                guard let material = materials[row.materialID], let section = sections[row.sectionID] else { return nil }
                return Target(material: material, section: section, topic: row.topic, isCore: row.strength == .core)
            }
            .sorted { ($0.material.isPrimary ? 0 : 1, $0.isCore ? 0 : 1, $0.section.firstPage) < ($1.material.isPrimary ? 0 : 1, $1.isCore ? 0 : 1, $1.section.firstPage) }
            return Covered(targets: targets)
        }

        /// The sections matched for this topic (folded title); without one, with `fallback` (Ask)
        /// or when no row names a topic, the core ones (at most 3).
        func sections(for title: String, fallback: Bool = false) -> [Target] {
            let folded = TextFolding.fold(title)
            let matched = targets.filter { !$0.topic.isEmpty && TextFolding.fold($0.topic) == folded }
            guard matched.isEmpty else { return matched }
            guard fallback || !targets.contains(where: { !$0.topic.isEmpty }) else { return [] }
            return Array(targets.filter(\.isCore).prefix(3))
        }
    }
}
