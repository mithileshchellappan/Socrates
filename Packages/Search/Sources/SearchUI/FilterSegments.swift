import SwiftUI

/// The All | Lectures | Notes filter (mockup `.segctl`): segments sized to their labels on a grey
/// track, the chosen one a raised neutral knob in medium weight, no dividers. The system
/// segmented control fills the chosen segment with the accent, which the screen keeps for its
/// one filled button. ←/→ step through the segments when the control has focus; VoiceOver sees a
/// segmented picker.
struct FilterSegments<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: LocalizedStringKey
    }

    @Binding var selection: Value
    let label: LocalizedStringKey
    let options: [Option]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index])
            }
        }
        .padding(2)
        .background(QuietFill(), in: .rect(cornerRadius: 8, style: .continuous))
        .fixedSize()
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            step(press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title).tag(options[index].value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ option: Option) -> some View {
        let isOn = option.value == selection
        return Button {
            selection = option.value
        } label: {
            // The medium-weight title reserves the width, so choosing a segment never moves the others.
            ZStack {
                Text(option.title).fontWeight(.medium).hidden()
                Text(option.title).fontWeight(isOn ? .medium : .regular)
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        }
                }
            }
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func step(_ offset: Int) {
        guard let index = options.firstIndex(where: { $0.value == selection }) else { return }
        let next = min(max(index + offset, 0), options.count - 1)
        selection = options[next].value
    }
}
