import Courses
import StudyCore
import StudyUI
import SwiftUI

/// A form section header with quiet accent actions on the trailing side ("Add Break").
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
                .headerActionStyle()
        }
    }
}

extension View {
    /// Plain accent-coloured 12 pt buttons, as in group headers ("Import .ics", "Add Slot").
    func headerActionStyle() -> some View {
        buttonStyle(.plain)
            .foregroundStyle(.tint)
            .font(.callout)
            .fontWeight(.regular)
    }
}

/// A titled group of rows (mockup 08): the 13 pt semibold title with its actions, then the rows
/// on a faint rounded panel with separators inset 12 pt. Rows bring their own padding. Without
/// rows only the title shows.
struct SettingsGroup<Content: View, Actions: View>: View {
    private let title: LocalizedStringKey
    private let actions: Actions
    private let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                HStack(spacing: 14) {
                    actions
                }
                .headerActionStyle()
            }
            .frame(height: 19)
            .padding(.horizontal, 4)

            Group(subviews: content) { rows in
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            if row.id != rows.first?.id {
                                SeparatorLine()
                                    .padding(.horizontal, 12)
                            }
                            row
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
                }
            }
        }
    }
}

extension SettingsGroup where Actions == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title, actions: { EmptyView() }, content: content)
    }
}

/// A 0.5 pt separator line.
struct SeparatorLine: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// A labelled row of a settings group: the label in a 92 pt column, the value trailing.
struct FormRow<Value: View>: View {
    private let label: Text
    private let value: Value

    init(_ label: Text, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    init(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) {
        self.init(Text(label), value: value)
    }

    var body: some View {
        HStack(spacing: 10) {
            label
                .frame(width: 92, alignment: .leading)
            HStack(spacing: 6) {
                value
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .settingsRowPadding()
    }
}

/// A row with a label and a green switch at the trailing edge ("Show in Calendar").
struct SwitchRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.green)
        }
        .settingsRowPadding()
    }
}

extension View {
    /// A settings row's box: at least 32 pt high, padded 5/12.
    func settingsRowPadding() -> some View {
        frame(minHeight: 22)
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
    }

    /// A text field's box outside a Form: window background, 0.5 pt border, radius 6, 22 pt high;
    /// the accent border with a focus ring while it is focused.
    func fieldChrome(isFocused: Bool, width: CGFloat? = 236) -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(width: width, height: 22)
            .background(Color.fieldBackground, in: .rect(cornerRadius: 6))
            .focusRing(isFocused, cornerRadius: 6)
    }

    /// The field border, and while focused the accent border with a 3 pt ring.
    func focusRing(_ isFocused: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isFocused ? 1 : 0.5)
                .allowsHitTesting(false)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius + 1.5)
                    .stroke(.tint.opacity(0.26), lineWidth: 3)
                    .padding(-1.5)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A value drawn as a token (mail rule values, glossary terms): accent-soft, 20 pt, radius 5.
    func tokenStyle(isSelected: Bool = false) -> some View {
        modifier(TokenStyle(isSelected: isSelected))
    }
}

private struct TokenStyle: ViewModifier {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(colorScheme == .dark ? 0.24 : 0.12)),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }
}

extension Color {
    /// The text background: white, near black in dark mode (the mockups' window colour).
    static var fieldBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// A choice of a pop-up or segmented control.
struct ChoiceOption<Value: Hashable>: Identifiable {
    var value: Value
    var label: String
    var id: Value { value }
}

/// A pop-up button that hugs its value (mockup 08): the value and ⇕ in a 22 pt field box.
struct PopUpPicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [ChoiceOption<Value>]

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(currentLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .padding(.leading, 9)
            .padding(.trailing, 4)
            .frame(height: 22)
            .background(Color.fieldBackground, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(currentLabel))
    }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }
}

/// A neutral segmented control (mockup 08): a filled track, the chosen segment raised in the
/// window colour. No accent: the choice is a setting, not an action.
struct SegmentedChoice<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [ChoiceOption<Value>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isOn = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.callout.weight(isOn ? .medium : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 18)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.fieldBackground)
                                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.9), in: .rect(cornerRadius: 8))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
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
            CourseDot(hex: hex, size: 8)
                .frame(width: 10, height: 14)
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

/// A text field that edits a list of names; the list changes when editing ends. With `chrome`,
/// it draws its own field box (outside a Form).
struct NamesField: View {
    let title: LocalizedStringKey
    @Binding var names: [String]
    var prompt: Text?
    var chrome = false
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if chrome {
            field
                .labelsHidden()
                .fieldChrome(isFocused: isFocused)
        } else {
            field
        }
    }

    private var field: some View {
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
