import StudyCore
import SwiftUI

/// Routes the sidebar selection to its screen. Screens are placeholders until their milestone.
struct DetailView: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .today:
            TodayView()
        case .calendar, .mail, .search:
            PlaceholderScreen(item: item)
        case .course(let id):
            CourseView(courseID: id)
                .id(id)
        }
    }
}

struct TodayView: View {
    var body: some View {
        ContentUnavailableView {
            Image(systemName: SidebarItem.today.systemImage)
        }
        .navigationTitle(SidebarItem.today.title)
        .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
    }
}

struct PlaceholderScreen: View {
    let item: SidebarItem

    var body: some View {
        ContentUnavailableView {
            Image(systemName: item.systemImage)
        }
        .navigationTitle(item.title)
    }
}

struct CourseView: View {
    @FetchOne private var course: Course?

    init(courseID: Course.ID) {
        _course = FetchOne(Course.find(courseID))
    }

    var body: some View {
        ContentUnavailableView {
            Image(systemName: "books.vertical")
        }
        .navigationTitle(course?.name ?? "")
        .navigationSubtitle(course?.professors.joined(separator: ", ") ?? "")
    }
}
