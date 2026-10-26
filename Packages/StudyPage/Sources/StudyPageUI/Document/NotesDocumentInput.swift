import Foundation
import StudyCore
import StudyUI

/// Where a chip in the notes points (a slide or a moment of a lecture; mt: a page of a course
/// material, its chip "§6.2 · p. 214" with the material's title as help).
public enum NotesChipTarget: Hashable, Sendable {
    case slide(lecture: Lecture.ID, page: Int)
    case moment(lecture: Lecture.ID, recording: Recording.ID?, seconds: Double)
    case material(id: CourseMaterial.ID, page: Int?, label: String, title: String)

    /// The lecture a slide or moment chip names (nil: a material's).
    public var lectureID: Lecture.ID? {
        switch self {
        case .slide(let lecture, _), .moment(let lecture, _, _): lecture
        case .material: nil
        }
    }
}

/// A course material as the notes' `[[mat …]]` chips are checked and labelled (mt): the key
/// names it, a page must lie within it, its sections give "§6.2".
public struct NotesMaterialRef: Equatable, Sendable {
    public var material: CourseMaterial
    public var sections: [MaterialSection]

    public init(material: CourseMaterial, sections: [MaterialSection]) {
        self.material = material
        self.sections = sections
    }

    /// "§6.2 · p. 214" (non-breaking).
    public func label(page: Int?) -> String {
        MaterialText.citeLabel(section: page.flatMap { MaterialSection.holding(page: $0, in: sections) }, material: material, pdfPage: page)
    }

    /// The course's materials by key; a key two share names neither (left out).
    public static func load(courseID: Course.ID, in db: Database) throws -> [String: NotesMaterialRef] {
        let materials = try MaterialRepository.materials(of: courseID, in: db)
        guard !materials.isEmpty else { return [:] }
        let ids = materials.map(\.id)
        let sections = try MaterialSection.where { $0.materialID.in(ids) }.order { $0.sortOrder.asc() }.fetchAll(db)
        var byKey: [String: [CourseMaterial]] = [:]
        for material in materials { byKey[material.key, default: []].append(material) }
        var refs: [String: NotesMaterialRef] = [:]
        for (key, found) in byKey where found.count == 1 {
            guard let material = found.first else { continue }
            refs[key] = NotesMaterialRef(material: material, sections: sections.filter { $0.materialID == material.id })
        }
        return refs
    }
}

/// Everything the notes document is drawn from: the current version, the student's marks, the
/// professor's rows, the lecture's slides and recordings, the page's inset and the content zoom,
/// and the view's own state (folded sections, open answers). Equal inputs draw the same document.
/// The student's own notes are not part of it (nl: they sit beside the text, in Your notes).
struct NotesDocumentInput: Equatable {
    struct LectureRef: Equatable {
        var id: Lecture.ID
        var number: Int?
    }

    var lectureID: Lecture.ID
    var style: LectureNotesStyle
    /// The appearance the inks and formula images are drawn for.
    var isDark = false
    /// `\.contentZoom`: every size of the document is multiplied by it.
    var zoom: CGFloat = 1
    /// The prose's indent on each side of the text view (`NotesPageLayout.inset`; 0 in Review's
    /// pane). A change re-indents the paragraphs, nothing is built again.
    var inset: CGFloat = 0
    var notes: LectureNotes?
    var marks: [LectureNotesMark] = []
    /// The lecture's exam hints and highlights (the professor's words for `quote` fences).
    var quotes: [Annotation] = []
    /// Lecture keys (`ChatCitation.key`) of the course's lectures.
    var lectures: [String: LectureRef] = [:]
    /// Recording keys of this lecture.
    var recordings: [String: Recording.ID] = [:]
    /// mt: the course's materials by key (`[[mat …]]` chips).
    var materials: [String: NotesMaterialRef] = [:]
    var hasRecording = false
    /// The lecture's slides.
    var deck: Deck?
    var pages: ClosedRange<Int>?
    var professor: String?
    var folded: Set<String> = []
    /// Check yourself blocks whose Answers are open ("<section>#<n>").
    var answersOpen: Set<String> = []
    /// Claude Code is not available: the readable sentence (nil: available or unknown).
    var unavailable: String?
    /// A new version could be written now (`LectureNotesInputs.available`): the failure line's
    /// Write Again… is off without it.
    var canWriteAgain = true
    /// How the lecture's recording is getting into the Summary: a blocked way is the document's
    /// first line ("Not transcribed", Retry).
    var recording: RecordingNotesState = .none

    var outline: [LectureNotesSection] { notes?.sections ?? [] }

    var chips: NotesChipResolver {
        NotesChipResolver(lectureID: lectureID, lectures: lectures, recordings: recordings, materials: materials)
    }
}

/// Citations to chips: a lecture key of the course (`ChatCitation.key`) to its lecture, a
/// recording key of this lecture to its recording, a material key of the course to its material
/// (mt; the page within it).
struct NotesChipResolver: Equatable, Sendable {
    var lectureID: Lecture.ID
    var lectures: [String: NotesDocumentInput.LectureRef]
    var recordings: [String: Recording.ID]
    var materials: [String: NotesMaterialRef] = [:]

    func target(_ citation: ChatCitation) -> NotesChipTarget? {
        switch citation {
        case .slide(let key, let page):
            guard let lecture = lectures[key] else { return nil }
            return .slide(lecture: lecture.id, page: page)
        case .moment(let key, let recording, let seconds):
            guard let lecture = lectures[key] else { return nil }
            return .moment(lecture: lecture.id, recording: recording.flatMap { recordings[$0] }, seconds: Double(seconds))
        case .web, .change, .document:
            return nil
        case .material(let key, let page):
            guard let ref = materials[key.lowercased()] else { return nil }
            if let page, page < 1 || page > ref.material.pageCount { return nil }
            return .material(id: ref.material.id, page: page, label: ref.label(page: page), title: ref.material.title)
        }
    }

    /// "L2" for another lecture of the course; nil for this one.
    func prefix(_ lecture: Lecture.ID) -> String? {
        guard lecture != lectureID else { return nil }
        return lectures.values.first { $0.id == lecture }?.number.map { "L\($0)" }
    }
}
