import RecorderContract

/// A remote command the phone tried and could not do (a Resume during a phone call): the Mac
/// shows it, the phone does not (its problem alert is for its own surfaces). Cleared by the next
/// action.
public struct RemoteProblem: Hashable, Sendable {
    public var action: RemoteAction
    public var failure: RecorderFailure

    public init(action: RemoteAction, failure: RecorderFailure) {
        self.action = action
        self.failure = failure
    }
}
