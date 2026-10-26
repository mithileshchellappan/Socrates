#if os(macOS)
import Foundation
import SQLiteData
import StudyCore
import StudyUI
import SwiftUI

/// Write Again… (the notes page's ⋯ and failure line, Review's Summary): the student's act,
/// through the app's action (`\.lectureNotesWriteAgain`: Retry of a blocked recording first, then
/// a new version from whatever there is, or, on a finished Summary whose recording's study pass is
/// on its way, the instruction kept until the pass writes the version from it), with the
/// popover's instruction or the standing one. Edit ▸ Undo "Undo Write Again": Previous Version
/// for a version queued, the instruction taken back for one that waits; Redo brings either back.
/// The task queue writes the version on the one background notes slot once Claude Code is ready.
@MainActor
public enum LectureNotesWriteAgain {
    public static func run(
        lectureID: Lecture.ID, instruction: NotesInstruction, action: LectureNotesWriteAgainAction?, services: StudyServices?,
        undoManager: UndoManager?
    ) {
        guard let action else {
            StudyPageLog.logger.notice("Write Again: no app action here (renders)")
            return
        }
        action(lectureID, instruction) { outcome in
            guard let services else { return }
            registerUndo(outcome, repository: LectureNotesRepository(store: services.records), lectureID: lectureID, undoManager: undoManager)
        }
    }

    private static func registerUndo(_ outcome: WriteAgainOutcome, repository: LectureNotesRepository, lectureID: Lecture.ID, undoManager: UndoManager?) {
        guard let undoManager else { return }
        let undo: @Sendable () async throws -> Void
        let redo: @Sendable () async throws -> Void
        switch outcome {
        case .queued(let notes):
            undo = { _ = try await repository.previousVersion(lectureID: lectureID) }
            redo = { try await repository.restore(notes.id) }
        case .waiting(let notes):
            undo = { try await repository.discard(notes.id) }
            redo = { try await repository.restore(notes.id) }
        case .writing, .nothingToWriteFrom:
            return
        }
        let target = NotesUndoTarget()
        undoManager.registerUndo(withTarget: target) { target in
            Task { try? await undo() }
            undoManager.registerUndo(withTarget: target) { _ in
                Task { try? await redo() }
            }
            undoManager.setActionName(String(localized: "Write Again"))
        }
        undoManager.setActionName(String(localized: "Write Again"))
    }
}

/// Write Again…'s popover: one optional line ("more on the merge rule, fewer formulas"), ↩ writes.
/// The host opens it with the student's standing instruction (`LectureNotes.instruction(of:)`),
/// editable; what it holds when it writes is the new standing instruction (empty clears it).
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

/// Review's Summary above the study pass's blocks: while the lecture's current notes failed, the
/// failure line (triangle, the reason, Write Again…, whose popover hangs off this plain view; a
/// version without text is queued again at once with the standing instruction); else, while the
/// recording's way into the Summary is blocked, its line ("Not transcribed", Retry). Nothing
/// otherwise.
public struct LectureNotesFailureBar: View {
    private let lectureID: Lecture.ID
    @Fetch private var state: LectureNotesWriteState
    @State private var shown = false
    @State private var request = ""
    @Environment(\.studyServices) private var services
    @Environment(\.undoManager) private var undoManager
    @Environment(\.lectureNotesRetry) private var retry
    @Environment(\.lectureNotesWriteAgain) private var writeAgain

    public init(lectureID: Lecture.ID) {
        self.lectureID = lectureID
        _state = Fetch(wrappedValue: LectureNotesWriteState(), LectureNotesWriteStateRequest(lectureID: lectureID))
    }

    public var body: some View {
        if let notes = state.current, notes.state == .failed {
            NotesFailureLine(label: notes.error, help: notes.error, action: .writeAgain, isEnabled: state.canWrite) {
                if notes.hasText {
                    request = state.instruction ?? ""
                    Task { @MainActor in shown = true }
                } else {
                    write(.standing)
                }
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                LectureNotesWriteAgainPopover(request: $request) { sentence in
                    shown = false
                    write(.new(sentence))
                }
            }
        } else if let line = NotesRecordingLine(state.recording) {
            NotesFailureLine(label: line.label, help: line.help, action: line.retries ? .retry : nil) {
                retry?(lectureID)
            }
        }
    }

    private func write(_ instruction: NotesInstruction) {
        LectureNotesWriteAgain.run(lectureID: lectureID, instruction: instruction, action: writeAgain, services: services, undoManager: undoManager)
    }
}

/// The current notes, whether a new version could be written now (`LectureNotesInputs.available`),
/// the student's standing instruction and how the recording is getting into the Summary.
struct LectureNotesWriteState: Equatable, Sendable {
    var current: LectureNotes?
    var canWrite = false
    var instruction: String?
    var recording: RecordingNotesState = .none
}

struct LectureNotesWriteStateRequest: FetchKeyRequest {
    let lectureID: Lecture.ID

    func fetch(_ db: Database) throws -> LectureNotesWriteState {
        let versions = try LectureNotesRepository.versions(lectureID: lectureID, in: db)
        let inputs = try LectureNotesRepository.inputs(lectureID: lectureID, in: db)
        return LectureNotesWriteState(
            current: LectureNotes.current(of: versions), canWrite: inputs.available != nil, instruction: LectureNotes.instruction(of: versions),
            recording: inputs.recording
        )
    }
}
#endif
