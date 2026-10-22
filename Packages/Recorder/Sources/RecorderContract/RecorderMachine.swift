import Foundation

/// The recorder's rules, without I/O: which commands a phase takes, whether a command applies,
/// and which ids were already decided. The executor (`PhoneRecorder.perform`) asks it before
/// acting, and the snapshot's `accepts` comes from the same `accepts` function, so what a button
/// offers and what the recorder takes cannot disagree.
///
///     command \ phase    recording         paused            stopping, stopped
///     pause              apply → paused    unchanged         rejected
///     resume             unchanged         apply → recording rejected
///     next/previous      apply (bounds,    rejected          rejected
///                        shown slide)
///     flag               apply             rejected          rejected
///     stop               apply → stopped   apply → stopped   unchanged
public struct RecorderMachine: Sendable {
    public enum Decision: Hashable, Sendable {
        /// Run the command.
        case apply
        /// Do nothing and answer this.
        case answer(RecorderOutcome.Result)
    }

    /// How many decided ids are kept per recording.
    public static let memory = 256

    private var recordingID: UUID?
    private var decided: Set<RecorderCommand.ID> = []
    private var order: [RecorderCommand.ID] = []

    public init() {}

    /// The commands a recorder in `phase` takes; the slide moves only within the deck.
    public static func accepts(phase: RecorderSnapshot.Phase, canGoNext: Bool, canGoPrevious: Bool) -> Set<RecorderCommand.Kind> {
        switch phase {
        case .recording:
            var kinds: Set<RecorderCommand.Kind> = [.pause, .flag, .stop]
            if canGoNext { kinds.insert(.nextSlide) }
            if canGoPrevious { kinds.insert(.previousSlide) }
            return kinds
        case .paused:
            return [.resume, .stop]
        case .stopping, .stopped:
            return []
        }
    }

    /// What to do with `command` given the recorder's state now (nil: nothing records).
    public func decide(_ command: RecorderCommand, current: RecorderSnapshot?) -> Decision {
        guard let current else { return .answer(.rejected(.noRecording)) }
        guard command.recordingID == current.recordingID else { return .answer(.rejected(.otherRecording)) }
        if recordingID == current.recordingID, decided.contains(command.id) { return .answer(.duplicate) }
        switch (command.action, current.phase) {
        case (.pause, .paused), (.resume, .recording), (.stop, .stopping), (.stop, .stopped):
            return .answer(.unchanged)
        default:
            break
        }
        let kind = command.action.kind
        guard current.accepts.contains(kind) else {
            let movesSlide = kind == .nextSlide || kind == .previousSlide
            return .answer(.rejected(current.phase == .recording && movesSlide ? .atEnd : .notAccepted(current.phase)))
        }
        if let shown = command.action.shownSlide, shown != current.slide {
            return .answer(.rejected(.staleSlide(shown: shown, current: current.slide)))
        }
        return .apply
    }

    /// Records how `command` ended, so a second delivery of its id is a duplicate. A failure is
    /// not kept (the same command may be retried), nor is a command for no or another recording.
    public mutating func settle(_ command: RecorderCommand, as result: RecorderOutcome.Result) {
        switch result {
        case .failed, .duplicate, .rejected(.noRecording), .rejected(.otherRecording):
            return
        case .applied, .unchanged, .rejected:
            break
        }
        if recordingID != command.recordingID {
            recordingID = command.recordingID
            decided = []
            order = []
        }
        guard decided.insert(command.id).inserted else { return }
        order.append(command.id)
        if order.count > Self.memory {
            decided.remove(order.removeFirst())
        }
    }
}
