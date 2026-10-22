#if os(macOS)
import Foundation
import SQLiteData
import StudyCore
import StudyUI
import SwiftUI

/// Write Again… (the notes page's ⋯ and failure line, Review's Summary): a new version with
/// the student's sentence, queued through `LectureNotesRepository.queue` (which logs why when it
/// queues nothing: a version is open, or there is nothing to write from), with Edit ▸ Undo "Undo
/// Write Again" (Previous Version; Redo brings the new one back). The task queue writes it on the
/// one background notes slot once Claude Code is ready.
@MainActor
public enum LectureNotesWriteAgain {
    public static func queue(lectureID: Lecture.ID, request: String, services: StudyServices, undoManager: UndoManager?) {
        let repository = LectureNotesRepository(store: services.records)
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                guard let queued = try await repository.queue(lectureID: lectureID, request: trimmed.isEmpty ? nil : trimmed, createdBy: .user)
                else { return }
                registerUndo(repository: repository, lectureID: lectureID, version: queued.id, undoManager: undoManager)
            } catch {
                StudyPageLog.logger.error("Queueing the lecture's notes failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func registerUndo(repository: LectureNotesRepository, lectureID: Lecture.ID, version: LectureNotes.ID, undoManager: UndoManager?) {
        guard let undoManager else { return }
        let target = NotesUndoTarget()
        undoManager.registerUndo(withTarget: target) { target in
            Task { _ = try? await repository.previousVersion(lectureID: lectureID) }
            undoManager.registerUndo(withTarget: target) { _ in
                Task { try? await repository.restore(version) }
            }
            undoManager.setActionName(String(localized: "Write Again"))
        }
        undoManager.setActionName(String(localized: "Write Again"))
    }
}

/// Write Again…'s popover: one optional line ("more on the merge rule, fewer formulas"), ↩ writes.
public struct LectureNotesWriteAgainPopover: View {
    @Binding var request: String
    let write: (String) -> Void
    @FocusState private var focused: Bool

    public init(request: Binding<String>, write: @escaping (String) -> Void) {
        _request = request
        self.write = write
    }

    public var body: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "What should change?"), text: $request)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused)
                .onSubmit { write(request) }
            Button("Write Again") { write(request) }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .onAppear { focused = true }
        .onChange(of: request) { _, text in
            if text.count > LectureNotes.requestLimit { request = String(text.prefix(LectureNotes.requestLimit)) }
        }
    }
}

/// Review's Summary while the lecture's current notes failed (the study pass's blocks stay
/// under it): the failure line, triangle, the reason and Write Again…, whose popover hangs off this
/// plain view; a version without text is queued again at once. Nothing otherwise.
public struct LectureNotesFailureBar: View {
    private let lectureID: Lecture.ID
    @Fetch private var state: LectureNotesWriteState
    @State private var shown = false
    @State private var request = ""
    @Environment(\.studyServices) private var services
    @Environment(\.undoManager) private var undoManager

    public init(lectureID: Lecture.ID) {
        self.lectureID = lectureID
        _state = Fetch(wrappedValue: LectureNotesWriteState(), LectureNotesWriteStateRequest(lectureID: lectureID))
    }

    public var body: some View {
        if let notes = state.current, notes.state == .failed {
            NotesFailureLine(reason: notes.error, canWrite: state.canWrite) {
                if notes.hasText {
                    Task { @MainActor in shown = true }
                } else {
                    write("")
                }
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                LectureNotesWriteAgainPopover(request: $request) { sentence in
                    shown = false
                    write(sentence)
                }
            }
        }
    }

    private func write(_ sentence: String) {
        guard let services else { return }
        request = ""
        LectureNotesWriteAgain.queue(lectureID: lectureID, request: sentence, services: services, undoManager: undoManager)
    }
}

/// The current notes and whether a new version could be written now (`LectureNotesRepository.source`).
struct LectureNotesWriteState: Equatable, Sendable {
    var current: LectureNotes?
    var canWrite = false
}

struct LectureNotesWriteStateRequest: FetchKeyRequest {
    let lectureID: Lecture.ID

    func fetch(_ db: Database) throws -> LectureNotesWriteState {
        LectureNotesWriteState(
            current: try LectureNotesRepository.current(lectureID: lectureID, in: db),
            canWrite: try LectureNotesRepository.source(lectureID: lectureID, in: db) != nil
        )
    }
}
#endif
