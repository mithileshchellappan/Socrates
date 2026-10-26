#if os(macOS)
import Foundation
import SQLiteData
import StudyCore
import StudyUI
import SwiftUI

/// Write Again… (the notes page's ⋯ and failure line, Review's Summary): the student's act. A new
/// version from whatever there is to write from (`LectureNotesRepository.writeAgain`, which logs
/// why when it queues nothing: a version is open, or there is nothing at all), with the
/// popover's instruction or the standing one, and Edit ▸ Undo "Undo Write Again" (Previous
/// Version; Redo brings the new one back). While the recording's way into the Summary can be
/// re-run (a failed transcription, the study pass's failed units), it is re-run too (`retry`):
/// when it lands, the Summary is written once more from the recording, with the same instruction.
/// The task queue writes the version on the one background notes slot once Claude Code is ready.
@MainActor
public enum LectureNotesWriteAgain {
    public static func queue(
        lectureID: Lecture.ID, instruction: NotesInstruction, retry: LectureNotesRetryAction?, services: StudyServices, undoManager: UndoManager?
    ) {
        let repository = LectureNotesRepository(store: services.records)
        let database = services.database
        Task {
            do {
                if let queued = try await repository.writeAgain(lectureID: lectureID, instruction: instruction, createdBy: .user) {
                    registerUndo(repository: repository, lectureID: lectureID, version: queued.id, undoManager: undoManager)
                }
                let recording = try await database.read { db in try LectureNotesRepository.inputs(lectureID: lectureID, in: db).recording }
                if recording.canRetry { retry?(lectureID) }
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
        guard let services else { return }
        LectureNotesWriteAgain.queue(lectureID: lectureID, instruction: instruction, retry: retry, services: services, undoManager: undoManager)
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
