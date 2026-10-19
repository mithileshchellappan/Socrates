import StudyCore

/// Observes rows without ever reading them on the main thread: the first fetch and every later
/// one run on the database's reader, and the values arrive on the main actor. SQLiteData's
/// default scheduler fetches the first value synchronously on main (in the view's body); load a
/// heavy request with this one instead (`$rows.load(request, scheduler: OffMainScheduler())`).
public struct OffMainScheduler: ValueObservationScheduler, Hashable {
    public init() {}

    public func immediateInitialValue() -> Bool { false }

    public func schedule(_ action: @escaping @Sendable () -> Void) {
        Task { @MainActor in action() }
    }
}
