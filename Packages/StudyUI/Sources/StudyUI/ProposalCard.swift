import SwiftUI

/// A proposed change that waits for the student (docs/DESIGN.md §5.3): a room move or a
/// cancellation read from mail or a lecture. Card surface, radius 12; the sparkle, the question
/// in 13 pt semibold and the source glyph trailing; one grey line saying what it changes; then
/// [Discard] plain and [Confirm], filled while it is the screen's first thing, else plain accent.
/// Nothing changes until Confirm.
///
///     ProposalCard(question: "Move to Room 5?", detail: "DC Lecture 4, Thu 22 Oct only",
///                  isFirstThing: true, discard: { … }, confirm: { … }) {
///         SourceTrailButton(entries: trail, now: now, inCalendar: false)
///     }
public struct ProposalCard<Source: View>: View {
    private let question: String
    private let detail: String
    private let isFirstThing: Bool
    private let discard: () -> Void
    private let confirm: () -> Void
    private let source: Source

    public init(
        question: String,
        detail: String,
        isFirstThing: Bool,
        discard: @escaping () -> Void,
        confirm: @escaping () -> Void,
        @ViewBuilder source: () -> Source
    ) {
        self.question = question
        self.detail = detail
        self.isFirstThing = isFirstThing
        self.discard = discard
        self.confirm = confirm
        self.source = source()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AIMark()
                    .frame(width: 13)
                Text(question)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                source
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .padding(.leading, 19)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Discard", action: discard)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                if isFirstThing {
                    Button("Confirm", action: confirm)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Confirm", action: confirm)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                }
            }
            .font(.system(size: 12.5))
            .padding(.top, 4)
        }
        .padding(.top, 10)
        .padding(.horizontal, 11)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}
