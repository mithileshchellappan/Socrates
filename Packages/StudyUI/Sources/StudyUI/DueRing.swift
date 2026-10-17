import StudyCore
import SwiftUI

/// Something due, in a list that mixes classes and due items (docs/DESIGN.md §4.8): a 10 pt open
/// ring with a 1.5 pt stroke in the course colour. A class or event gets `CourseBarRow`'s bar.
public struct DueRing: View {
    private let color: Color

    public init(color: Color) {
        self.color = color
    }

    public init(course: Course?) {
        color = .course(course)
    }

    public static let size: CGFloat = 10

    public var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 1.5)
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }
}
