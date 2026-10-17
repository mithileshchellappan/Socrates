import Courses
import StudyCore
import StudyUI
import SwiftUI

/// A form section header with quiet actions on the trailing side ("Add Slot").
struct SectionHeader<Actions: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var actions: Actions

    init(_ title: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer(minLength: 8)
            actions
                .buttonStyle(.borderless)
                .font(.callout)
                .fontWeight(.regular)
        }
    }
}

/// "L2 · 0:37": jumps to the moment a rule was said (SF Mono capsule, like `TimeChip`).
struct LectureTimeChip: View {
    let lectureNumber: Int?
    let seconds: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .monospacedDigit()
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .foregroundStyle(.tint)
                .background(.tint.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Play from \(TimeText.clock(seconds))"))
    }

    private var label: String {
        if let lectureNumber { return "L\(lectureNumber) · \(TimeText.clock(seconds))" }
        return TimeText.clock(seconds)
    }
}

/// A menu whose label is plain text (weekly-slot cells): no bezel, no indicator.
struct PlainMenu<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Picks a course colour from the palette; the label is the course dot.
struct CourseColorMenu: View {
    @Binding var hex: String

    var body: some View {
        Menu {
            Picker("Colour", selection: $hex) {
                ForEach(CourseDraft.palette, id: \.self) { color in
                    Label {
                        Text(color)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(Color(hex: color) ?? .accentColor)
                    }
                    .tag(color)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            CourseDot(hex: hex, size: 9)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Colour"))
    }
}

/// Swatches for a new course's colour.
struct ColorSwatches: View {
    @Binding var hex: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CourseDraft.palette, id: \.self) { color in
                Button {
                    hex = color
                } label: {
                    Circle()
                        .fill(Color(hex: color) ?? .accentColor)
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay {
                            if color == hex {
                                Circle().strokeBorder(.secondary, lineWidth: 1.5)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(color))
                .accessibilityAddTraits(color == hex ? .isSelected : [])
            }
        }
    }
}

/// A text field that edits a list of names; the list changes when editing ends.
struct NamesField: View {
    let title: LocalizedStringKey
    @Binding var names: [String]
    var prompt: Text?
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: prompt)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) {
                if !isFocused { commit() }
            }
            .onAppear { text = names.joined(separator: ", ") }
            .onChange(of: names) {
                if !isFocused { text = names.joined(separator: ", ") }
            }
    }

    private func commit() {
        let parsed = CourseDraft.names(from: text)
        if parsed != names { names = parsed }
        text = parsed.joined(separator: ", ")
    }
}

/// Language choices for a picker: the usual ones plus whatever the course already has.
func languageChoices(including current: String...) -> [(code: String, name: String)] {
    var choices = CourseDraft.languages
    for code in current where !code.isEmpty && !choices.contains(where: { $0.code == code }) {
        choices.append((code, CourseDraft.languageName(code)))
    }
    return choices
}

extension Course {
    /// Same values, `updatedAt` aside.
    func hasSameContent(as other: Course) -> Bool {
        var copy = self
        copy.updatedAt = other.updatedAt
        return copy == other
    }
}

extension Semester {
    func hasSameContent(as other: Semester) -> Bool {
        var copy = self
        copy.updatedAt = other.updatedAt
        return copy == other
    }
}

/// `Date` ↔ minutes after midnight for hour-and-minute pickers (read in UTC, so no DST).
enum MinuteClock {
    static let reference = CalendarDay(year: 2001, month: 1, day: 1).start(in: .gmt)

    static func date(_ minute: Int) -> Date {
        reference.addingTimeInterval(Double(minute) * 60)
    }

    static func minute(_ date: Date) -> Int {
        let seconds = Int(date.timeIntervalSince(reference).rounded())
        return ((seconds / 60) % 1440 + 1440) % 1440
    }
}

/// `Date` ↔ `CalendarDay` for date pickers (noon UTC, read in UTC).
enum DayClock {
    static func date(_ day: CalendarDay) -> Date {
        day.date(minute: 12 * 60, in: .gmt)
    }

    static func day(_ date: Date) -> CalendarDay {
        CalendarDay(date, in: .gmt)
    }
}
