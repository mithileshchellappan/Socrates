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
    /// The Mail screen showing `scope`, with `message` selected (M2).
    case mail(MailScope, message: MailMessage.ID?)
    /// The Notes screen showing `scope`, with `note` selected (M6).
    case notes(NotesScope, note: Note.ID?)
    /// mc: the Study screen (the coach across courses; the sidebar row after Notes).
    case study
    /// mc: a course's Progress screen (readiness, budget, topics and reading).
    case courseProgress(Course.ID)
    /// mc: a round or a practice exam in progress, full window (the sidebar hides; an exam also
    /// hides the agent panel and the search field until it is submitted).
    case practice(StudySession.ID)
    /// mc: a submitted practice exam's results, pushed on its course's Progress with the sidebar back.
    case practiceResults(StudySession.ID)
    /// md: the Documents screen (the sidebar row after Notes) with `document` selected (nil: the
    /// newest), from a search hit, a `[[doc …]]` chip or a course's related documents. `page`: the
    /// page a hit or chip names (the reader shows the document; Quick Look opens at its start).
    case documents(StudyDocument.ID?, page: Int?)
    /// ln: a lecture's notes (docs/plan-lecture-notes.md), pushed full width on its course's
    /// Lectures (the sidebar keeps the course's Lectures row selected; the toolbar's Back returns to
    /// the list).
    case lectureNotes(Lecture.ID)

    public static func lecture(_ id: Lecture.ID) -> StudyDestination { .lecture(id, ReviewTarget()) }

    /// A message in the Inbox (search hits, Today's mail line, a deadline's source).
    public static func mail(_ messageID: MailMessage.ID) -> StudyDestination { .mail(.inbox, message: messageID) }
}

/// Which messages the Mail screen lists: the sidebar's mail rows (mockup 05).
public enum MailScope: Hashable, Sendable {
    /// Every message in the Inbox, course mail included.
    case inbox
    /// One course's mail (Inbox and Archive).
    case course(Course.ID)
    /// A category's mail other than `course`: University, Newsletters.
    case category(MailCategory)
    /// Drafts not sent yet (`mail_draft` rows in `draft`, `generating` or `failed`).
    case drafts
    /// The Sent mailbox.
    case sent
}

/// Which notes the Notes screen lists (M6, mockup 04): every note (All Notes, grouped by course)
/// or one course's (the sidebar's course rows under Notes, and the course's own Notes screen).
public enum NotesScope: Hashable, Sendable {
    case all
    case course(Course.ID)
}

/// Where the review screen should open: a slide, a moment on the recording clock, or both (the
/// time wins for the player, the page for the slide when they disagree).
public struct ReviewTarget: Hashable, Sendable {
    /// 1-based deck page.
    public var page: Int?
    /// Seconds on the recording clock (`recordingID`'s, else the lecture's first recording's).
    public var time: Double?
    /// Start playing from `time`.
    public var plays: Bool
    /// The recording `time` is on, for a lecture with more than one (a second recording of the
    /// same class, a backup recorder); nil: the lecture's first.
    public var recordingID: Recording.ID?
    /// Set by the app once per request to open (`openDestination`), so that opening the same
    /// place again moves there again; nil for a plain open.
    public var request: UUID?

    public init(page: Int? = nil, time: Double? = nil, plays: Bool = false, recordingID: Recording.ID? = nil, request: UUID? = nil) {
        self.page = page
        self.time = time
        self.plays = plays
        self.recordingID = recordingID
        self.request = request
    }

    /// Nothing to move to: the screen opens where review left off.
    public var isEmpty: Bool { page == nil && time == nil && !plays }
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

    /// The window's toolbar search field has keyboard focus (the app sets it from its
    /// `@FocusState`). Screens with plain-key shortcuts detach them while it is true.
    @Entry public var isSearchFieldFocused = false
}

/// Room the window's floating overlays (smart import's toasts) keep free at the bottom, so they
/// never cover a screen's own floating controls (the review player). The window that shows the
/// overlays installs one (`\.overlayInsets`); a screen reserves space with `reservesBottomOverlaySpace`.
@MainActor
@Observable
public final class OverlayInsets {
    /// Points from the bottom edge the overlays stay above (0: none reserved).
    public var bottom: CGFloat = 0

    public init() {}
}

extension EnvironmentValues {
    @Entry public var overlayInsets: OverlayInsets?
}

extension View {
    /// While this view is on screen, the window's floating overlays stay above the bottom
    /// `height` points (the top edge of this screen's own bottom controls).
    public func reservesBottomOverlaySpace(_ height: CGFloat) -> some View {
        modifier(BottomOverlaySpace(height: height))
    }
}

private struct BottomOverlaySpace: ViewModifier {
    let height: CGFloat
    @Environment(\.overlayInsets) private var insets

    func body(content: Content) -> some View {
        content
            .onAppear { insets?.bottom = height }
            .onChange(of: height) { _, height in insets?.bottom = height }
            .onDisappear { if insets?.bottom == height { insets?.bottom = 0 } }
    }
}
