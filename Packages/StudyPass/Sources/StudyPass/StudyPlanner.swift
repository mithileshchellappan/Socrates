import ClaudeKit
import CryptoKit
import Deadlines
import Foundation
import StudyCore

extension AnnotationKind {
    /// Internal to the pass (never shown): what a read unit saw on a figure slide's image (body ≤
    /// 25 words, page). Synthesis reads it; Opus never sees the image.
    static let studyFigure: Self = "study_figure"
    /// Internal to the pass (never shown): a line a read unit marked for synthesis (body
    /// `exam` / `highlight` / `said`, `category` for `said`, `transcript_segment_id`).
    static let studyCandidate: Self = "study_candidate"
}

/// The rows the pass wrote for one lecture (its units and their annotations).
struct PassRows: Sendable {
    var units: [StudyUnit]
    var annotations: [Annotation]
    /// mt: the lecture's coverage that counts (`MaterialCoverage.effective`): book first.
    var coverage: [MaterialCoverage] = []
    /// mt: the covering materials that are a book or the course's primary material (the ones
    /// `CoverStage.verify` writes further reading for).
    var bookMaterials: Set<CourseMaterial.ID> = []

    static func load(_ lectureID: Lecture.ID, in db: Database) throws -> PassRows {
        let stages = StudyPlanner.stages
        let units = try StudyUnit.where { $0.lectureID.eq(lectureID) && $0.stage.in(stages) }.fetchAll(db)
        let annotations = try Annotation
            .where { $0.lectureID.eq(lectureID) && $0.studyUnitID.isNot(nil) }
            .fetchAll(db)
        let coverage = MaterialCoverage.effective(try MaterialCoverage.where { $0.lectureID.eq(lectureID) }.fetchAll(db))
        var books: Set<CourseMaterial.ID> = []
        if !coverage.isEmpty {
            let ids = Array(Set(coverage.map(\.materialID)))
            books = Set(try CourseMaterial.where { $0.id.in(ids) }.fetchAll(db).filter { $0.kind == .book || $0.isPrimary }.map(\.id))
        }
        return PassRows(units: units, annotations: annotations, coverage: coverage, bookMaterials: books)
    }

    /// Folded titles of the topics a course book (or the primary material) covers at its core:
    /// research skips them, as the book's further reading replaces it.
    var bookTopics: Set<String> {
        Set(coverage.filter { $0.strength == .core && !$0.topic.isEmpty && bookMaterials.contains($0.materialID) }.map { TextFolding.fold($0.topic) })
    }

    func units(_ stage: StudyStage) -> [StudyUnit] {
        units.filter { $0.stage == stage }
    }

    /// Annotations of `kind` written by units of `stage`, in a fixed order (page, time, body).
    func annotations(_ kind: AnnotationKind, of stage: StudyStage) -> [Annotation] {
        let ids = Set(units(stage).map(\.id))
        return annotations
            .filter { $0.kind == kind && $0.studyUnitID.map(ids.contains) == true }
            .sorted {
                ($0.pageNumber ?? -1, $0.startTime ?? -1, $0.body, $0.id.uuidString)
                    < ($1.pageNumber ?? -1, $1.startTime ?? -1, $1.body, $1.id.uuidString)
            }
    }
}

/// A block of a read unit: deck pages 1–12, 13–24, … (time order inside), or 15 minutes of a
/// lecture without slides.
struct ReadBlock: Sendable {
    var key: String
    /// Indices into `LectureMaterial.sections`, in time order (empty for a time block).
    var sections: [Int]
    /// Indices into `LectureMaterial.lines`, in time order.
    var lines: [Int]
    /// "13-24" or nil (time block).
    var pageRange: ClosedRange<Int>?
    /// "0-15" (minutes) for a time block.
    var minutes: ClosedRange<Int>?
    var words: Int
}

/// A further-reading pick of synthesis: a topic row with its query (`detail`) and slide.
struct ResearchPick: Sendable {
    var title: String
    var query: String
    var page: Int?

    /// "research:" + 12 hex characters of SHA-256(folded title, query, slide): a synthesis re-run
    /// that picks the same topic keeps its done unit and its further-reading rows (the topic
    /// row's id changes with every re-run).
    var unitKey: String {
        var hasher = SHA256()
        for part in [TextFolding.fold(title), TextFolding.fold(query), page.map(String.init) ?? "-"] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return StudyPlanner.researchPrefix + hex.prefix(12)
    }
}

/// One unit as planned now.
struct UnitSpec: Sendable {
    enum Work: Sendable {
        case read(ReadBlock)
        case synthesize
        case research(ResearchPick)
        /// mt: the sections the lecture covers (nil: an existing unit kept as it is).
        case cover(CoverInput?)
    }

    var stage: StudyStage
    var key: String
    var work: Work
    var prompt: StudyPrompt?
    var inputHash: String
    /// Too little to read (no call): `skipped`.
    var skip: Bool
}

/// mt: whether the lecture gets a `cover` unit (CoverStage), decided before planning.
enum CoverPlan: Sendable {
    /// No unit: no coverable material, or no topics yet.
    case none
    /// No retriever on this device now: an existing unit stays as it is (never deleted).
    case keep(StudyUnit)
    case input(CoverInput)
}

/// Plans a lecture's units (plan §3.1). Local, no call.
enum StudyPlanner {
    static let pagesPerBlock = 12
    static let maximumBlockWords = 6_000
    static let minutesPerBlock = 15
    /// Read blocks with fewer spoken words are skipped without a call.
    static let minimumSpokenWords = 30
    /// A lecture with fewer spoken words gets no synthesis.
    static let minimumLectureWords = 100
    static let synthesisKey = "lecture"
    static let researchPrefix = "research:"
    /// The pass's own stages. mc: other stages (the coach's `quiz` units) share `study_unit` and
    /// are never planned, reset, failed or deleted by the pass.
    static let stages: [StudyStage] = [.read, .synthesize, .cover, .research]

    /// Reads first (in page or time order), then the synthesis, then (mt) the cover unit, then the
    /// research picks; a pick whose topic a course book covers at its core is skipped (book
    /// first), unless its web run is done already (its rows stay).
    static func plan(_ material: LectureMaterial, rows: PassRows, cover: CoverPlan = .none) -> [UnitSpec] {
        var specs: [UnitSpec] = []
        for block in readBlocks(material) {
            let prompt = ReadStage.prompt(block, in: material)
            let skip = block.words < minimumSpokenWords
            specs.append(UnitSpec(
                stage: .read, key: block.key, work: .read(block), prompt: skip ? nil : prompt,
                inputHash: prompt.inputHash(model: ReadStage.model, effort: ReadStage.effort), skip: skip))
        }

        let words = material.lines.reduce(0) { $0 + $1.wordCount }
        let synthesis = SynthesisStage.prompt(material, rows: rows)
        let skipSynthesis = words < minimumLectureWords
        specs.append(UnitSpec(
            stage: .synthesize, key: synthesisKey, work: .synthesize, prompt: skipSynthesis ? nil : synthesis,
            inputHash: synthesis.inputHash(model: SynthesisStage.model, effort: SynthesisStage.effort), skip: skipSynthesis))

        switch cover {
        case .none:
            break
        case .keep(let unit):
            specs.append(UnitSpec(stage: .cover, key: CoverStage.key, work: .cover(nil), prompt: nil, inputHash: unit.inputHash, skip: true))
        case .input(let input):
            let prompt = CoverStage.prompt(input)
            let skip = input.candidates.isEmpty
            specs.append(UnitSpec(
                stage: .cover, key: CoverStage.key, work: .cover(input), prompt: skip ? nil : prompt,
                inputHash: prompt.inputHash(model: CoverStage.model, effort: CoverStage.effort), skip: skip))
        }

        var researchKeys: Set<String> = []
        let bookTopics = rows.bookTopics
        for pick in researchPicks(rows) {
            let key = pick.unitKey
            guard researchKeys.insert(key).inserted else { continue }
            let prompt = ResearchStage.prompt(pick, in: material)
            let hash = prompt.inputHash(model: ResearchStage.model, effort: ResearchStage.effort)
            let done = rows.units(.research).contains { $0.key == key && $0.state == .done }
            if !done, bookTopics.contains(TextFolding.fold(pick.title)) {
                specs.append(UnitSpec(stage: .research, key: key, work: .research(pick), prompt: nil, inputHash: hash + ":book", skip: true))
                continue
            }
            specs.append(UnitSpec(stage: .research, key: key, work: .research(pick), prompt: prompt, inputHash: hash, skip: false))
        }
        return specs
    }

    // MARK: Blocks

    static func readBlocks(_ material: LectureMaterial) -> [ReadBlock] {
        material.hasSlides ? pageBlocks(material) : timeBlocks(material)
    }

    /// Sections by block of deck pages; an off-slide stretch joins the block of the slide before
    /// it (the first slide's block when it comes first); a block over 6,000 words splits at a
    /// section boundary ("p13-24.1", "p13-24.2").
    static func pageBlocks(_ material: LectureMaterial) -> [ReadBlock] {
        var blockOf: [Int: Int] = [:]
        var current: Int?
        var leading: [Int] = []
        for section in material.sections where !section.lines.isEmpty {
            if let page = section.page {
                let block = max(0, (page - 1) / pagesPerBlock)
                blockOf[section.index] = block
                for index in leading { blockOf[index] = block }
                leading = []
                current = block
            } else if let current {
                blockOf[section.index] = current
            } else {
                leading.append(section.index)
            }
        }
        var sectionsByBlock: [Int: [Int]] = [:]
        for section in material.sections where blockOf[section.index] != nil {
            sectionsByBlock[blockOf[section.index] ?? 0, default: []].append(section.index)
        }
        var blocks: [ReadBlock] = []
        for block in sectionsByBlock.keys.sorted() {
            let first = block * pagesPerBlock + 1
            let range = first...(first + pagesPerBlock - 1)
            let key = "p\(range.lowerBound)-\(range.upperBound)"
            let sections = sectionsByBlock[block] ?? []
            var chunks: [[Int]] = [[]]
            var chunkWords = 0
            for index in sections {
                let words = material.sections[index].lines.reduce(0) { $0 + material.lines[$1].wordCount }
                if chunkWords + words > maximumBlockWords, !(chunks.last ?? []).isEmpty {
                    chunks.append([])
                    chunkWords = 0
                }
                chunks[chunks.count - 1].append(index)
                chunkWords += words
            }
            for (number, chunk) in chunks.enumerated() where !chunk.isEmpty {
                let lines = chunk.flatMap { material.sections[$0].lines }
                blocks.append(ReadBlock(
                    key: chunks.count == 1 ? key : "\(key).\(number + 1)", sections: chunk, lines: lines, pageRange: range,
                    minutes: nil, words: lines.reduce(0) { $0 + material.lines[$1].wordCount }))
            }
        }
        return blocks
    }

    /// 15-minute blocks for a lecture without slides ("t0-15", "t15-30", …), on the lecture's
    /// timeline (with several recordings, the second part's minutes follow the first's).
    static func timeBlocks(_ material: LectureMaterial) -> [ReadBlock] {
        var byBlock: [Int: [Int]] = [:]
        for line in material.lines {
            byBlock[max(0, Int(line.clock / Double(minutesPerBlock * 60))), default: []].append(line.index)
        }
        return byBlock.keys.sorted().map { block in
            let lines = byBlock[block] ?? []
            let minutes = (block * minutesPerBlock)...((block + 1) * minutesPerBlock)
            return ReadBlock(
                key: "t\(minutes.lowerBound)-\(minutes.upperBound)", sections: [], lines: lines, pageRange: nil, minutes: minutes,
                words: lines.reduce(0) { $0 + material.lines[$1].wordCount })
        }
    }

    // MARK: Research

    /// Topics of the synthesis that carry a research query (`detail`), with the slide synthesis
    /// named for them (a slide citation), else the topic's first slide.
    static func researchPicks(_ rows: PassRows) -> [ResearchPick] {
        rows.annotations(.topic, of: .synthesize).compactMap { topic in
            guard let query = topic.detail, !query.isEmpty else { return nil }
            let page = topic.citations.first { $0.kind == .slide }?.pageNumber ?? topic.pageNumber
            return ResearchPick(title: topic.body, query: query, page: page)
        }
    }

    // MARK: Reconcile

    /// Brings `study_unit` in line with the plan, in one transaction: a new unit is inserted
    /// (`pending`, or `skipped` when too short); a unit whose hash changed goes back to `pending`
    /// with its attempts reset (or `skipped`, its rows deleted); an unchanged unit is left alone
    /// (done stays done, failed stays failed); a unit no longer planned is deleted (its rows
    /// cascade). Only the pass's own `stages` (a `quiz` unit survives). Returns the units in plan
    /// order.
    static func reconcile(_ specs: [UnitSpec], lectureID: Lecture.ID, in db: Database, store: RecordStore, now: Date) throws -> [StudyUnit] {
        var existing: [String: StudyUnit] = [:]
        let stages = stages
        for unit in try StudyUnit.where({ $0.lectureID.eq(lectureID) && $0.stage.in(stages) }).order(by: \.createdAt).fetchAll(db) {
            let key = unit.stage.rawValue + "/" + unit.key
            if existing[key] == nil {
                existing[key] = unit
            } else {
                // Unique per (lecture, stage, key) by code: a duplicate goes.
                try StudyUnit.find(unit.id).delete().execute(db)
            }
        }
        var planned: [StudyUnit] = []
        var keep: Set<UUID> = []
        for spec in specs {
            let key = spec.stage.rawValue + "/" + spec.key
            if var unit = existing[key] {
                keep.insert(unit.id)
                if unit.inputHash != spec.inputHash {
                    unit.inputHash = spec.inputHash
                    unit.attempts = 0
                    unit.error = nil
                    unit.apiCallID = nil
                    if spec.skip {
                        unit.state = .skipped
                        unit.finishedAt = now
                        try Annotation.where { $0.studyUnitID.eq(unit.id) }.delete().execute(db)
                    } else {
                        unit.state = .pending
                        unit.finishedAt = nil
                    }
                    let stamped = store.stamp(unit)
                    try StudyUnit.upsert { stamped }.execute(db)
                    unit = stamped
                }
                planned.append(unit)
            } else {
                let unit = store.stamp(StudyUnit(
                    lectureID: lectureID, stage: spec.stage, key: spec.key, inputHash: spec.inputHash,
                    state: spec.skip ? .skipped : .pending, finishedAt: spec.skip ? now : nil, createdAt: now))
                try StudyUnit.upsert { unit }.execute(db)
                keep.insert(unit.id)
                planned.append(unit)
            }
        }
        for unit in existing.values where !keep.contains(unit.id) {
            try StudyUnit.find(unit.id).delete().execute(db)
        }
        return planned
    }
}
