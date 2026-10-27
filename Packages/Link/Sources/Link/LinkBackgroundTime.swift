import RecorderContract

/// The phone's time to finish after the app leaves the foreground (UIKit's background task,
/// through the app's `MacLink.BeginBackgroundTime`), held at most once at a time. Stop ends the
/// audio session before the package is closed, and a locked phone may be suspended from then on,
/// so it is begun before any Stop runs: by `MacLink` the moment the recorder shows one, by the
/// agent before it runs the Mac's. The agent decides when it ends (the Mac received the
/// recording, no Mac is reachable, nothing needs sending); iOS may take it back first.
@MainActor
final class LinkBackgroundTime {
    private let begin: MacLink.BeginBackgroundTime?
    private var end: (@MainActor @Sendable () -> Void)?
    /// Called when iOS takes the time back.
    var onExpiry: (@MainActor () -> Void)?

    init(begin: MacLink.BeginBackgroundTime?) {
        self.begin = begin
    }

    /// It is held (begun and neither ended nor taken back).
    var isHeld: Bool { end != nil }

    /// A Stop between two of the recorder's snapshots: one beginning (`stopping`), or one seen
    /// only once done (live before, not now). The moment the time is held.
    nonisolated static func stopBegan(from old: RecorderSnapshot?, to new: RecorderSnapshot?) -> Bool {
        new?.phase == .stopping || ((old?.isLive ?? false) && !(new?.isLive ?? false))
    }

    /// Begins it unless it is held.
    func hold() {
        guard end == nil, let begin else { return }
        end = begin("Socrates recording link") { [weak self] in
            self?.expired()
        }
    }

    /// Ends it if it is held.
    func release() {
        end?()
        end = nil
    }

    private func expired() {
        release()
        onExpiry?()
    }
}
