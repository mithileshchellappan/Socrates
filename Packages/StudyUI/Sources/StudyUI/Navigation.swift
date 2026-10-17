import StudyCore
import SwiftUI

/// Shared SwiftUI building blocks and the contract between feature UI modules and the app.
public enum StudyUIModule {
    public static let moduleName = "StudyUI"
}

/// Where a feature screen can send the user. Feature modules never own the window's navigation:
/// they call `openDestination` and the app routes (sidebar selection, navigation stack, window).
public enum StudyDestination: Hashable, Sendable {
    case today
    case calendar
    /// The search screen with this query.
    case search(String)
    /// A course's page (course setup in M1).
    case course(Course.ID)
    /// A lecture's review screen, optionally at a slide and/or second.
    case lecture(Lecture.ID, ReviewTarget)

    public static func lecture(_ id: Lecture.ID) -> StudyDestination { .lecture(id, ReviewTarget()) }
}

/// Where the review screen should open: a slide, a moment on the recording clock, or both (the
/// time wins for the player, the page for the slide when they disagree).
public struct ReviewTarget: Hashable, Sendable {
    /// 1-based deck page.
    public var page: Int?
    /// Seconds on the lecture's recording clock.
    public var time: Double?
    /// Start playing from `time`.
    public var plays: Bool

    public init(page: Int? = nil, time: Double? = nil, plays: Bool = false) {
        self.page = page
        self.time = time
        self.plays = plays
    }
}

/// Opens a `StudyDestination`; the app installs the real one (`.environment(\.openDestination, …)`).
public struct OpenDestinationAction: Sendable {
    private let handler: @MainActor @Sendable (StudyDestination) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (StudyDestination) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ destination: StudyDestination) {
        handler(destination)
    }
}

extension EnvironmentValues {
    /// Navigation for feature screens. Does nothing until the app installs it.
    @Entry public var openDestination = OpenDestinationAction { _ in }

    /// The library (database, blobs, paths) for writes. Views observe rows with `@FetchAll` /
    /// `@FetchOne` on SQLiteData's default database, which the app points at the same database.
    @Entry public var studyServices: StudyServices?
}
