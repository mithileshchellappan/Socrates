import StudyCore
import StudyUI
import SwiftUI

/// A sidebar row's label for a mail scope (mockup 05): the glyph or the course dot, the name and
/// the unread count as the row's badge (Drafts: open drafts; Sent: none). Every label observes the
/// same one query, so a sidebar of mail rows reads the counts once per change.
///
///     NavigationLink(value: SidebarItem.mail(.inbox)) { MailScopeLabel(scope: .inbox) }
public struct MailScopeLabel: View {
    private let scope: MailScope
    @Fetch private var counts: MailCounts

    public init(scope: MailScope) {
        self.scope = scope
        _counts = Fetch(wrappedValue: MailCounts(), MailCountsRequest())
    }

    public var body: some View {
        Label {
            Text(scope.title(courses: counts.courses))
        } icon: {
            if case .course(let id) = scope {
                CourseDot(course: counts.courses[id], size: 9)
            } else {
                Image(systemName: scope.systemImage)
            }
        }
        .badge(counts.count(for: scope))
    }
}
