import RecorderContract

/// A button of the Mac remote.
public enum RemoteAction: Hashable, Sendable {
    case pause, resume, nextSlide, stop

    /// The command kind the phone's snapshot must accept for it.
    var kind: RecorderCommand.Kind {
        switch self {
        case .pause: .pause
        case .resume: .resume
        case .nextSlide: .nextSlide
        case .stop: .stop
        }
    }
}
