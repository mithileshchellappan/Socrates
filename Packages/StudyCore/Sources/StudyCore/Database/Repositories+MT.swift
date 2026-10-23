import Foundation
import SQLiteData

// Repositories added with schema v18 (mt: course materials). The rules (classifying, reading,
// fetching, the card, coverage, passages) live in Documents' `Materials`, Search, StudyPass and
// AppAgent; these only read and write rows. docs/plan-materials.md §3–4.

/// A course's materials (`course_material`, `material_section`, `material_coverage`).
public struct MaterialRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    // MARK: Reading

    /// A course's materials in shelf order (`CourseMaterial.shelfOrder`).
    public func materials(of courseID: Course.ID) async throws -> [CourseMaterial] {
        try await store.database.read { db in try Self.materials(of: courseID, in: db) }
    }

    public static func materials(of courseID: Course.ID, in db: Database) throws -> [CourseMaterial] {
        try CourseMaterial.where { $0.courseID.eq(courseID) }.fetchAll(db).sorted(by: CourseMaterial.shelfOrder)
    }

    public func material(_ id: CourseMaterial.ID) async throws -> CourseMaterial? {
        try await store.fetch(CourseMaterial.self, id: id)
    }

    /// The materials whose key (`CourseMaterial.key`, the first 8 hex of the id) is `key`: one,
    /// or none (a citation or tool argument naming two is refused by its caller).
    public func materials(key: String) async throws -> [CourseMaterial] {
        let key = key.lowercased()
        guard key.count == 8, key.allSatisfy(\.isHexDigit) else { return [] }
        return try await store.database.read { db in
            try CourseMaterial.all.fetchAll(db).filter { $0.key == key }
        }
    }

    /// Every material of a document (one file can serve two courses).
    public func materials(documentID: StudyDocument.ID) async throws -> [CourseMaterial] {
        try await store.database.read { db in try Self.materials(documentID: documentID, in: db) }
    }

    public static func materials(documentID: StudyDocument.ID, in db: Database) throws -> [CourseMaterial] {
        let reference = StudyDocument.ID?.some(documentID)
        return try CourseMaterial.where { $0.documentID.eq(reference) }.order { $0.addedAt.asc() }.fetchAll(db)
    }

    /// Materials still being read or fetched (a quit interrupted them), oldest first: the library
    /// resumes them at launch.
    public func pending() async throws -> [CourseMaterial] {
        try await store.database.read { db in
            try CourseMaterial.where { $0.state.eq(MaterialState.pending) }.order { $0.addedAt.asc() }.fetchAll(db)
        }
    }

    /// The course's ready file materials that have sections, primary first (the study pass plans
    /// `cover` units only while there is one; notes passages come from these).
    public func coverable(courseID: Course.ID) async throws -> [CourseMaterial] {
        try await store.database.read { db in try Self.coverable(courseID: courseID, in: db) }
    }

    public static func coverable(courseID: Course.ID, in db: Database) throws -> [CourseMaterial] {
        let withSections = Set(try MaterialSection.all.select { $0.materialID }.fetchAll(db))
        return try materials(of: courseID, in: db).filter {
            $0.kind.isFile && $0.state == .ready && $0.documentID != nil && withSections.contains($0.id)
        }
    }

    /// The course's book: its primary material, else its first ready book.
    public func primaryBook(of courseID: Course.ID) async throws -> CourseMaterial? {
        let shelf = try await materials(of: courseID)
        return shelf.first(where: \.isPrimary) ?? shelf.first { $0.kind == .book && $0.state == .ready }
    }

    /// A material's sections in order (chapters with their sections after them).
    public func sections(of materialID: CourseMaterial.ID) async throws -> [MaterialSection] {
        try await store.database.read { db in try Self.sections(of: materialID, in: db) }
    }

    public static func sections(of materialID: CourseMaterial.ID, in db: Database) throws -> [MaterialSection] {
        try MaterialSection.where { $0.materialID.eq(materialID) }.order { ($0.sortOrder.asc(), $0.firstPage.asc()) }.fetchAll(db)
    }

    public func section(_ id: MaterialSection.ID) async throws -> MaterialSection? {
        try await store.fetch(MaterialSection.self, id: id)
    }

    /// The coverage that counts for a lecture (`MaterialCoverage.effective`).
    public func coverage(lectureID: Lecture.ID) async throws -> [MaterialCoverage] {
        try await store.database.read { db in
            MaterialCoverage.effective(try MaterialCoverage.where { $0.lectureID.eq(lectureID) }.fetchAll(db))
        }
    }

    /// The coverage that counts for a material (the reader's "L3 · L4").
    public func coverage(materialID: CourseMaterial.ID) async throws -> [MaterialCoverage] {
        try await store.database.read { db in
            MaterialCoverage.effective(try MaterialCoverage.where { $0.materialID.eq(materialID) }.fetchAll(db))
        }
    }

    // MARK: Writing

    /// Adds a material at the end of its course's shelf (`sort_order` = the largest + 1).
    @discardableResult
    public func add(_ material: CourseMaterial) async throws -> CourseMaterial {
        let stamped = store.stamp(material)
        let courseID = material.courseID
        return try await store.database.write { db in
            var row = stamped
            let last = try CourseMaterial.where { $0.courseID.eq(courseID) }.fetchAll(db).map(\.sortOrder).max()
            row.sortOrder = (last ?? -1) + 1
            try CourseMaterial.upsert { row }.execute(db)
            return row
        }
    }

    /// Changes a material's row (state, card, counts, …); nothing when it is gone.
    @discardableResult
    public func update(_ id: CourseMaterial.ID, _ change: @Sendable (inout CourseMaterial) -> Void) async throws -> CourseMaterial? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            guard var material = try CourseMaterial.find(id).fetchOne(db) else { return nil }
            change(&material)
            material.updatedAt = stamp
            try CourseMaterial.upsert { material }.execute(db)
            return material
        }
    }

    /// Where the reader was (PDF page).
    public func setLastPage(_ id: CourseMaterial.ID, page: Int) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try CourseMaterial.find(id).update { $0.lastPage = Int?.some(page); $0.updatedAt = stamp }.execute(db)
        }
    }

    /// Makes `id` the course's book (nil: none); every other material of the course stops being
    /// primary. Returns the primary material before.
    @discardableResult
    public func setPrimary(_ id: CourseMaterial.ID?, courseID: Course.ID) async throws -> CourseMaterial.ID? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let shelf = try CourseMaterial.where { $0.courseID.eq(courseID) }.fetchAll(db)
            let before = shelf.first(where: \.isPrimary)?.id
            for var material in shelf where material.isPrimary != (material.id == id) {
                material.isPrimary = material.id == id
                material.updatedAt = stamp
                try CourseMaterial.upsert { material }.execute(db)
            }
            return before
        }
    }

    /// Writes a material's sections found by a (re-)read, keeping each row whose key is known
    /// (its id, so coverage and the chapter summary stay; the summary only while the pages did not
    /// change), adding new keys and deleting keys no longer found (their coverage cascades). One
    /// transaction. Returns the sections as written.
    @discardableResult
    public func replaceSections(of materialID: CourseMaterial.ID, with found: [MaterialSection]) async throws -> [MaterialSection] {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let known = Dictionary(try Self.sections(of: materialID, in: db).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            var kept: Set<MaterialSection.ID> = []
            var written: [MaterialSection] = []
            for (index, section) in found.enumerated() {
                var row = section
                if let old = known[section.key], !kept.contains(old.id) {
                    row = MaterialSection(
                        id: old.id, materialID: materialID, key: old.key, number: section.number, title: section.title,
                        level: section.level, kind: section.kind, firstPage: section.firstPage, lastPage: section.lastPage,
                        printedFirst: section.printedFirst, source: section.source,
                        summary: old.pages == section.pages ? old.summary : "",
                        summaryHash: old.pages == section.pages ? old.summaryHash : nil,
                        apiCallID: old.pages == section.pages ? old.apiCallID : nil, sortOrder: index, updatedAt: stamp
                    )
                    kept.insert(old.id)
                } else {
                    row.materialID = materialID
                    row.sortOrder = index
                    row.updatedAt = stamp
                }
                try MaterialSection.upsert { row }.execute(db)
                written.append(row)
            }
            let gone = known.values.map(\.id).filter { !kept.contains($0) }
            if !gone.isEmpty {
                try MaterialSection.where { $0.id.in(gone) }.delete().execute(db)
            }
            return written
        }
    }

    /// A chapter's summary written (`materials.chapter`).
    public func setSummary(sectionID: MaterialSection.ID, summary: String, summaryHash: String, apiCallID: APICall.ID?) async throws {
        let stamp = store.currentDate
        let text = String(summary.prefix(MaterialSection.summaryLimit))
        try await store.database.write { db in
            try MaterialSection.find(sectionID)
                .update { $0.summary = text; $0.summaryHash = String?.some(summaryHash); $0.apiCallID = apiCallID; $0.updatedAt = stamp }
                .execute(db)
        }
    }

    /// Queues a chapter's summary (`agent_task` kind `material_chapter`, no tools) in one
    /// transaction; nothing (nil) when the section is gone, has a summary, its material has no
    /// document, or an open task for it exists. The reader calls it the first time a chapter is
    /// current; `read_material` may too.
    @discardableResult
    public func queueChapterSummary(_ sectionID: MaterialSection.ID, by author: Author) async throws -> AgentTask? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            guard let section = try MaterialSection.find(sectionID).fetchOne(db), section.summary.isEmpty,
                  let material = try CourseMaterial.find(section.materialID).fetchOne(db), let documentID = material.documentID
            else { return nil }
            let goal = section.taskGoal
            let open = try AgentTask
                .where { $0.kind.eq(AgentTaskKind.materialChapter) && $0.goal.eq(goal) && $0.state.in(AgentTaskState.open) }
                .fetchCount(db)
            guard open == 0 else { return nil }
            let label = section.number.isEmpty ? section.title : "\(section.number) \(section.title)"
            let task = AgentTask(
                kind: .materialChapter, title: "Summarize \u{201C}\(label)\u{201D}", goal: goal,
                model: MaterialCalls.chapterModel, effort: MaterialCalls.chapterEffort, tools: [],
                courseID: material.courseID, documentID: documentID, createdBy: author, createdAt: stamp, updatedAt: stamp
            )
            try AgentTask.upsert { task }.execute(db)
            return task
        }
    }

    /// The student's word on whether `lectureID` covers `sectionID` (`set_lecture_coverage`): their
    /// row for the pair is written (replacing an earlier student row), and wins over the pass's.
    /// Returns the student row before (nil: none) and after.
    public func setStudentCoverage(
        lectureID: Lecture.ID, sectionID: MaterialSection.ID, covers: Bool, quote: String?
    ) async throws -> (before: MaterialCoverage?, after: MaterialCoverage)? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            try Self.setStudentCoverage(lectureID: lectureID, sectionID: sectionID, covers: covers, quote: quote, in: db, stamp: stamp)
        }
    }

    /// `setStudentCoverage` inside the caller's transaction (several sections with one change row).
    public static func setStudentCoverage(
        lectureID: Lecture.ID, sectionID: MaterialSection.ID, covers: Bool, quote: String?, in db: Database, stamp: Date
    ) throws -> (before: MaterialCoverage?, after: MaterialCoverage)? {
        guard let section = try MaterialSection.find(sectionID).fetchOne(db) else { return nil }
        let rows = try MaterialCoverage
            .where { $0.lectureID.eq(lectureID) && $0.sectionID.eq(sectionID) && $0.source.eq(CoverageSource.student) }
            .order { $0.updatedAt.desc() }
            .fetchAll(db)
        let before = rows.first
        if rows.count > 1 { try MaterialCoverage.where { $0.id.in(rows.dropFirst().map(\.id)) }.delete().execute(db) }
        let after = MaterialCoverage(
            id: before?.id ?? UUID(), lectureID: lectureID, materialID: section.materialID, sectionID: sectionID,
            score: 1, strength: .core, source: .student, covers: covers, quote: quote, createdBy: .user,
            createdAt: before?.createdAt ?? stamp, updatedAt: stamp
        )
        try MaterialCoverage.upsert { after }.execute(db)
        return (before, after)
    }

    /// Undo of `setStudentCoverage`: the student's row as it was, or none.
    public func restoreStudentCoverage(lectureID: Lecture.ID, sectionID: MaterialSection.ID, to before: MaterialCoverageValues?) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try Self.restoreStudentCoverage(lectureID: lectureID, sectionID: sectionID, to: before, in: db, stamp: stamp)
        }
    }

    /// `restoreStudentCoverage` inside the caller's transaction.
    public static func restoreStudentCoverage(
        lectureID: Lecture.ID, sectionID: MaterialSection.ID, to before: MaterialCoverageValues?, in db: Database, stamp: Date
    ) throws {
        try MaterialCoverage
            .where { $0.lectureID.eq(lectureID) && $0.sectionID.eq(sectionID) && $0.source.eq(CoverageSource.student) }
            .delete()
            .execute(db)
        if let before, try MaterialSection.find(before.sectionID).fetchCount(db) > 0 {
            let row = before.row(updatedAt: stamp)
            try MaterialCoverage.upsert { row }.execute(db)
        }
    }

    // MARK: Deleting

    /// Deletes materials in one transaction: their rows (sections and coverage cascade), their
    /// book further-reading rows (ai · further_reading citing them by `SourceRef.materialID`) and
    /// their book readings (`study_reading.material_id`). Returns every row for `restore`. The
    /// documents are the library's (`MaterialLibrary.delete`).
    public func delete(_ ids: [CourseMaterial.ID]) async throws -> MaterialDeletion {
        guard !ids.isEmpty else { return MaterialDeletion() }
        return try await store.database.write { db in
            let materials = try CourseMaterial.where { $0.id.in(ids) }.fetchAll(db)
            guard !materials.isEmpty else { return MaterialDeletion() }
            let found = materials.map(\.id)
            let sections = try MaterialSection.where { $0.materialID.in(found) }.fetchAll(db)
            let coverage = try MaterialCoverage.where { $0.materialID.in(found) }.fetchAll(db)
            let wanted = Set(found)
            let readings = try StudyReading.all.fetchAll(db).filter { $0.materialID.map(wanted.contains) ?? false }
            let furtherReading = try Annotation.where { $0.kind.eq(AnnotationKind.furtherReading) }.fetchAll(db).filter { row in
                row.citations.contains { $0.kind == .material && ($0.materialID.map(wanted.contains) ?? false) }
            }
            if !readings.isEmpty { try StudyReading.where { $0.id.in(readings.map(\.id)) }.delete().execute(db) }
            if !furtherReading.isEmpty { try Annotation.where { $0.id.in(furtherReading.map(\.id)) }.delete().execute(db) }
            try CourseMaterial.where { $0.id.in(found) }.delete().execute(db)
            return MaterialDeletion(
                materials: materials, sections: sections, coverage: coverage, furtherReading: furtherReading, readings: readings
            )
        }
    }

    /// Undo of `delete`: every row as it was. A coverage or further-reading row whose study unit,
    /// lecture or topic is gone meanwhile (a re-run) stays gone.
    public func restore(_ deletion: MaterialDeletion) async throws {
        try await store.database.write { db in
            for material in deletion.materials {
                guard try Course.find(material.courseID).fetchCount(db) > 0 else { continue }
                try CourseMaterial.upsert { material }.execute(db)
            }
            let restored = Set(try CourseMaterial.where { $0.id.in(deletion.materials.map(\.id)) }.fetchAll(db).map(\.id))
            for section in deletion.sections where restored.contains(section.materialID) {
                try MaterialSection.upsert { section }.execute(db)
            }
            for row in deletion.coverage where restored.contains(row.materialID) {
                guard try Lecture.find(row.lectureID).fetchCount(db) > 0 else { continue }
                if let unit = row.studyUnitID, try StudyUnit.find(unit).fetchCount(db) == 0 { continue }
                var row = row
                if let topic = row.topicID, try Annotation.find(topic).fetchCount(db) == 0 { row.topicID = nil }
                if let segment = row.transcriptSegmentID, try TranscriptSegment.find(segment).fetchCount(db) == 0 { row.transcriptSegmentID = nil }
                try MaterialCoverage.upsert { row }.execute(db)
            }
            for row in deletion.furtherReading {
                if let unit = row.studyUnitID, try StudyUnit.find(unit).fetchCount(db) == 0 { continue }
                if let lecture = row.lectureID, try Lecture.find(lecture).fetchCount(db) == 0 { continue }
                try Annotation.upsert { row }.execute(db)
            }
            for reading in deletion.readings {
                guard try Course.find(reading.courseID).fetchCount(db) > 0 else { continue }
                var reading = reading
                if let lecture = reading.lectureID, try Lecture.find(lecture).fetchCount(db) == 0 { reading.lectureID = nil }
                if let topic = reading.topicID, try Annotation.find(topic).fetchCount(db) == 0 { reading.topicID = nil }
                if let source = reading.sourceAnnotationID, try Annotation.find(source).fetchCount(db) == 0 { reading.sourceAnnotationID = nil }
                if let unit = reading.studyUnitID, try StudyUnit.find(unit).fetchCount(db) == 0 { reading.studyUnitID = nil }
                if let material = reading.materialID, !restored.contains(material) { reading.materialID = nil }
                if let section = reading.materialSectionID, try MaterialSection.find(section).fetchCount(db) == 0 { reading.materialSectionID = nil }
                try StudyReading.upsert { reading }.execute(db)
            }
        }
    }
}
