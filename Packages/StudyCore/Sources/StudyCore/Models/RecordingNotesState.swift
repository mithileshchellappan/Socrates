import Foundation

/// How a lecture's recording is getting into its Summary, derived from rows
/// (`LectureNotesRepository.inputs`): each recording's transcript lines and latest transcription
/// (`JobRepository.transcriptions`), the lecture's open jobs and the study pass's synthesis unit.
/// Never stored. A blocked state is the Summary's one line (StudyPageUI) and lets the notes write
/// from what there is (`LectureNotesInputs.source`); Retry re-runs what `canRetry` names.
public enum RecordingNotesState: Sendable, Hashable {
    /// No recording, or its study pass synthesis is written.
    case none
    /// On its way: a job of the lecture is queued or running, a recording has no transcription
    /// yet, or its transcript waits for the study pass's synthesis.
    case coming
    /// A recording has no transcript lines and its latest transcription failed or was cancelled;
    /// `reason` is that job's error (help only).
    case transcriptionFailed(reason: String?)
    /// Too little was said to write from: every recording came back without lines, or the
    /// transcript is under the synthesis's minimum (its unit `skipped`).
    case tooLittleSpeech
    /// The study pass's synthesis failed (`overBudget`: the generation ran over the lecture's
    /// budget, `StudyUnit.overBudget`).
    case studyPassFailed(overBudget: Bool)

    /// Derives the state. Precedence: a failed transcription, then anything on its way, then a
    /// failed synthesis, then too little speech.
    public init(transcriptions: [RecordingTranscription], busy: Bool, synthesis: ExtractionState?, synthesisError: String?) {
        guard !transcriptions.isEmpty else {
            self = .none
            return
        }
        if let failed = transcriptions.first(where: \.hasFailed) {
            self = .transcriptionFailed(reason: failed.error)
            return
        }
        if busy || transcriptions.contains(where: { $0.lines == 0 && $0.latest != .succeeded }) {
            self = .coming
            return
        }
        guard transcriptions.contains(where: { $0.lines > 0 }) else {
            self = .tooLittleSpeech
            return
        }
        switch synthesis {
        case nil, .pending?: self = .coming
        case .done?: self = .none
        case .failed?: self = .studyPassFailed(overBudget: synthesisError == StudyUnit.overBudget)
        case .skipped?: self = .tooLittleSpeech
        }
    }

    /// The recording's way into the Summary is blocked: the notes are written from what there is.
    public var isBlocked: Bool {
        switch self {
        case .transcriptionFailed, .tooLittleSpeech, .studyPassFailed: true
        case .none, .coming: false
        }
    }

    /// Something can be re-run: a failed transcription, or the study pass's failed units.
    public var canRetry: Bool {
        switch self {
        case .transcriptionFailed, .studyPassFailed: true
        case .none, .coming, .tooLittleSpeech: false
        }
    }

    /// For the log ("transcription failed"): states only, never lecture content.
    public var logDescription: String {
        switch self {
        case .none: "none"
        case .coming: "coming"
        case .transcriptionFailed: "transcription failed"
        case .tooLittleSpeech: "too little speech"
        case .studyPassFailed(let overBudget): overBudget ? "study pass over budget" : "study pass failed"
        }
    }
}

/// One recording of a lecture on its way to a transcript (`JobRepository.transcriptions`).
public struct RecordingTranscription: Sendable, Hashable {
    public var recordingID: Recording.ID
    /// Its transcript lines in the lecture.
    public var lines: Int
    /// Its latest transcribe job's state (nil: none yet) and error.
    public var latest: JobState?
    public var error: String?

    public init(recordingID: Recording.ID, lines: Int, latest: JobState?, error: String?) {
        self.recordingID = recordingID
        self.lines = lines
        self.latest = latest
        self.error = error
    }

    /// No lines, and its latest transcription failed or was cancelled: Retry queues it again.
    public var hasFailed: Bool { lines == 0 && (latest == .failed || latest == .cancelled) }
}
