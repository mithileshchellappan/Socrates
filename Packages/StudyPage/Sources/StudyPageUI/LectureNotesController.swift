#if os(macOS)
import AppKit
import Foundation
import Observation
import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

/// A settled selection in the notes: the passage as the student selected it, the part it is in and
/// its text-quote anchor, and the highlights it touches.
struct NotesSelection: Equatable {
    var range: NSRange
    /// Plain text (attachments dropped), ≤ `LectureNotesMark.exactLimit`.
    var exact: String
    var prefix: String
    var suffix: String
    var sectionKey: String
    /// Where it is in its part's text (a hint for finding it again).
    var start: Int
    var end: Int
    /// The student's highlights it touches (Remove Highlight takes them all).
    var highlights: [LectureNotesMark.ID]

    /// A selection of at least one word.
    var hasWords: Bool { exact.contains { $0.isLetter || $0.isNumber } }
}

/// The identity the notes' undo steps are registered with.
@MainActor
final class NotesUndoTarget {}

/// One notes view's state and actions: folds (kept per lecture), open answers, focus, the settled
/// selection, the passage taken to the chat; highlight, Ask, Keep, remove, each with Edit ▸ Undo.
@MainActor
@Observable
final class LectureNotesController {
    let lectureID: Lecture.ID
    let style: LectureNotesStyle

    @ObservationIgnored var services: StudyServices?
    @ObservationIgnored var asker: (any LectureNotesAsking)?
    @ObservationIgnored var openDestination = OpenDestinationAction { _ in }
    @ObservationIgnored var openAgentPanel = OpenAgentPanelAction { _ in }
    @ObservationIgnored var onChip: ((NotesChipTarget) -> Bool)?
    @ObservationIgnored var onWriteAgain: (() -> Void)?
    /// Retry of the recording's way into the Summary (`\.lectureNotesRetry`; nil in renders).
    @ObservationIgnored var retry: LectureNotesRetryAction?
    /// Write Again (`\.lectureNotesWriteAgain`; nil in renders).
    @ObservationIgnored var writeAgainAction: LectureNotesWriteAgainAction?
    /// Review's Summary: the passage taken to the chat goes up to the review, which sends it
    /// with its own context (a preference from the inspector column may not reach the panel, and
    /// would replace the review's). Nil: the view publishes `chatPassage` itself (the page).
    @ObservationIgnored var onChatPassage: ((NotesPassageContext?) -> Void)?
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored weak var coordinator: NotesTextCoordinator?
    /// The current version and the marks on it (set from the view's rows).
    @ObservationIgnored var notes: LectureNotes?
    @ObservationIgnored var marks: [LectureNotesMark] = []
    @ObservationIgnored var chips = NotesChipResolver(lectureID: UUID(), lectures: [:], recordings: [:])
    @ObservationIgnored private let undoTarget = NotesUndoTarget()
    /// Orphan states already written back (so a redraw does not write them again).
    @ObservationIgnored private var written: [LectureNotesMark.ID: Bool] = [:]

    var folded: Set<String> {
        didSet { saveFolds() }
    }
    var answersOpen: Set<String> = []
    var isFocused = false
    var selection: NotesSelection?
    /// Continue in Chat: the passage (and the Ask exchange) the agent panel gets as context, until
    /// a message carries it, a new selection settles or an Ask starts.
    var chatPassage: NotesPassageContext?

    init(lectureID: Lecture.ID, style: LectureNotesStyle) {
        self.lectureID = lectureID
        self.style = style
        let stored = UserDefaults.standard.string(forKey: Self.foldKey(lectureID)) ?? ""
        folded = Set(stored.split(separator: ",").map(String.init))
    }

    private static func foldKey(_ id: Lecture.ID) -> String {
        "lectureNotes.folded.\(id.uuidString)"
    }

    private func saveFolds() {
        UserDefaults.standard.set(folded.sorted().joined(separator: ","), forKey: Self.foldKey(lectureID))
    }

    private var repository: LectureNotesRepository? {
        services.map { LectureNotesRepository(store: $0.records) }
    }

    // MARK: Folding

    func toggleFold(_ key: String) {
        if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
    }

    func toggleAnswers(_ key: String) {
        if answersOpen.contains(key) { answersOpen.remove(key) } else { answersOpen.insert(key) }
    }

    // MARK: Chips

    /// A chip: the host first (Review moves its own review), else Review opens at the slide or
    /// plays from the moment.
    func open(_ target: NotesChipTarget) {
        if onChip?(target) == true { return }
        switch target {
        case .slide(let lecture, let page):
            openDestination(.lecture(lecture, ReviewTarget(page: page)))
        case .moment(let lecture, let recording, let seconds):
            openDestination(.lecture(lecture, ReviewTarget(time: seconds, plays: true, recordingID: recording)))
        case .material(let id, let page, _, _):
            openDestination(.material(id, page: page))
        }
    }

    /// Write Again… on the failure line: the host's (the page's popover), else at once with the
    /// student's standing instruction (Review's Summary).
    func writeAgain() {
        if let onWriteAgain {
            onWriteAgain()
            return
        }
        LectureNotesWriteAgain.run(
            lectureID: lectureID, instruction: .standing, action: writeAgainAction, services: services,
            undoManager: undoManager ?? coordinator?.textView?.undoManager
        )
    }

    /// Retry on the recording's line: its failed transcriptions and the study pass's failed units
    /// run again.
    func retryRecording() {
        retry?(lectureID)
    }

    // MARK: Highlights

    /// The capsule's highlighter, the menu's Highlight / Remove Highlight, ⇧⌘E.
    func toggleHighlight() {
        guard let selection, selection.hasWords, let repository, let notes else { return }
        if !selection.highlights.isEmpty {
            let ids = selection.highlights
            remove(ids, repository: repository, name: String(localized: "Remove Highlight"))
        } else {
            let mark = LectureNotesMark(
                lectureID: lectureID, notesID: notes.id, kind: .highlight, sectionKey: selection.sectionKey, exact: selection.exact,
                prefix: selection.prefix, suffix: selection.suffix, startOffset: selection.start, endOffset: selection.end
            )
            add(mark, repository: repository, name: String(localized: "Highlight"))
        }
        coordinator?.clearSelection()
    }

    // MARK: Ask and Keep

    func ask(style: NotesAskStyle? = nil) {
        guard asker != nil, let selection, selection.hasWords else { return }
        clearChatPassage()
        coordinator?.showAsk(selection, style: style)
    }

    /// Keep (⌘↩): the exchange as a callout under the paragraph where the passage ends.
    func keep(_ exchange: NotesAskExchange, passage: NotesSelection, update: NotesAskUpdate?) {
        guard let repository, let notes else { return }
        let mark = LectureNotesMark(
            lectureID: lectureID, notesID: notes.id, kind: .answer, sectionKey: passage.sectionKey, exact: passage.exact,
            prefix: passage.prefix, suffix: passage.suffix, startOffset: passage.start, endOffset: passage.end,
            question: exchange.question, answer: exchange.answer, model: update?.model ?? LectureNotesCalls.askModel,
            apiCallID: update?.apiCallID, costUSD: update?.costUSD
        )
        add(mark, repository: repository, name: String(localized: "Keep"))
    }

    func removeKept(_ mark: LectureNotesMark) {
        guard let repository else { return }
        remove([mark.id], repository: repository, name: String(localized: "Remove from Summary"))
    }

    /// Continue in Chat: the passage and the exchange so far go to the agent panel as context.
    func continueInChat(passage exact: String, sectionKey: String, exchange: [NotesAskExchange]) {
        guard let notes else { return }
        let passage = NotesPassageContext(lectureID: lectureID, notesID: notes.id, sectionKey: sectionKey, exact: exact, exchange: exchange)
        if let onChatPassage {
            onChatPassage(passage)
        } else {
            chatPassage = passage
        }
        openAgentPanel()
    }

    /// The passage stops going with the next message (a new selection settled, an Ask started).
    func clearChatPassage() {
        if chatPassage != nil { chatPassage = nil }
        onChatPassage?(nil)
    }

    /// The panel read the context for a message (`AgentContextSource.refine` runs once, at ↩):
    /// the passage went with it.
    func chatPassageSent() {
        Task { @MainActor [weak self] in
            guard let self, self.chatPassage != nil else { return }
            self.chatPassage = nil
        }
    }

    func continueInChat(_ mark: LectureNotesMark) {
        let exchange = mark.question.map { [NotesAskExchange(question: $0, answer: mark.answer ?? "")] } ?? []
        continueInChat(passage: mark.exact, sectionKey: mark.sectionKey, exchange: exchange)
    }

    // MARK: Writing marks (with Undo)

    private func add(_ mark: LectureNotesMark, repository: LectureNotesRepository, name: String) {
        Task {
            do {
                try await repository.addMark(mark)
            } catch {
                StudyPageLog.logger.error("Saving a mark failed: \(String(describing: error), privacy: .public)")
            }
        }
        let id = mark.id
        registerUndo(name, undo: { try? await repository.removeMark(id) }, redo: { try? await repository.restoreMark(id) })
    }

    private func remove(_ ids: [LectureNotesMark.ID], repository: LectureNotesRepository, name: String) {
        Task {
            for id in ids { try? await repository.removeMark(id) }
        }
        registerUndo(name, undo: {
            for id in ids { try? await repository.restoreMark(id) }
        }, redo: {
            for id in ids { try? await repository.removeMark(id) }
        })
    }

    private func registerUndo(_ name: String, undo: @escaping @MainActor @Sendable () async -> Void, redo: @escaping @MainActor @Sendable () async -> Void) {
        guard let manager = undoManager ?? coordinator?.textView?.undoManager else { return }
        manager.registerUndo(withTarget: undoTarget) { [weak self] _ in
            Task { await undo() }
            self?.registerUndo(name, undo: redo, redo: undo)
        }
        manager.setActionName(name)
    }

    // MARK: Orphans

    /// Marks found again or not in a version that is done: written back once.
    func syncOrphans(found: Set<LectureNotesMark.ID>, orphaned: Set<LectureNotesMark.ID>) {
        guard let repository else { return }
        var changes: [(LectureNotesMark.ID, Bool)] = []
        for mark in marks {
            let isOrphan = orphaned.contains(mark.id)
            let isFound = found.contains(mark.id)
            guard isOrphan || isFound else { continue }
            let stored = mark.orphanedAt != nil
            guard stored != isOrphan, written[mark.id] != isOrphan else { continue }
            written[mark.id] = isOrphan
            changes.append((mark.id, isOrphan))
        }
        guard !changes.isEmpty else { return }
        Task {
            for (id, orphaned) in changes { try? await repository.setOrphaned(id, orphaned) }
        }
    }

    // MARK: Commands (the Lecture menu)

    var askCommand: LectureNotesCommand? {
        guard isFocused else { return nil }
        let enabled = asker != nil && (selection?.hasWords ?? false)
        return LectureNotesCommand(title: String(localized: "Ask…"), isEnabled: enabled) { [weak self] in self?.ask() }
    }

    var highlightCommand: LectureNotesCommand? {
        guard isFocused else { return nil }
        let removes = !(selection?.highlights.isEmpty ?? true)
        return LectureNotesCommand(
            title: removes ? String(localized: "Remove Highlight") : String(localized: "Highlight"),
            isEnabled: selection?.hasWords ?? false
        ) { [weak self] in self?.toggleHighlight() }
    }
}
#endif
