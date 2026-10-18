import StudyCore
import SwiftUI

/// What an `AnnotationPin` opens (docs/DESIGN.md §5.1, mockup 03 `.pin-card`): 268 pt wide,
/// 12.5 pt text, 6 pt between its parts. The professor's card is the quote over the who line
/// (`PinCardQuote`), the AI's the further reading rows (`FurtherReadingRow`), yours your own text.
/// Shown in a system popover (radius 12).
public struct PinCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .font(.system(size: 12.5))
        .lineSpacing(1.5)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(width: PinCardMetrics.width, alignment: .leading)
    }
}

public enum PinCardMetrics {
    /// The card's width (mockup `.pin-card`).
    public static let width: CGFloat = 268
}

/// The professor's exact words in “” (primary: the professor is marked by the pin, never by
/// amber text), over the 11 pt who line: the 16 pt professor pin, the surname and a time chip that
/// plays from the quote's first word.
public struct PinCardQuote: View {
    private let quote: String
    private let who: String
    private let time: Double?
    private let play: (Double) -> Void

    public init(quote: String, who: String, time: Double?, play: @escaping (Double) -> Void) {
        self.quote = quote
        self.who = who
        self.time = time
        self.play = play
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "“\(quote)”")
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                ProvenancePin(.professor)
                if !who.isEmpty {
                    Text(who)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let time {
                    TimeChip(time) { play(time) }
                }
            }
        }
    }
}

/// A further reading source the study pass verified: its title (12.5 medium, secondary: the AI
/// found it) over "byline · 🌐 domain" (11 pt, tertiary). A click opens the page in the browser.
public struct FurtherReadingRow: View {
    private let title: String
    private let byline: String?
    private let url: URL?
    @Environment(\.openURL) private var openURL

    public init(title: String, byline: String?, url: URL?) {
        self.title = title
        self.byline = byline
        self.url = url
    }

    public var body: some View {
        Button {
            if let url { openURL(url) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineSpacing(1)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = sourceLine {
                    line
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .pointerStyle(url == nil ? .default : .link)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }

    /// "Barham et al. · SOSP 2003 · 🌐 dl.acm.org".
    private var sourceLine: Text? {
        let byline = byline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let domain = url.flatMap(Self.domain)
        switch (byline.isEmpty, domain) {
        case (true, nil): return nil
        case (false, nil): return Text(byline)
        case (true, let domain?): return Text("\(Image(systemName: "globe")) \(domain)")
        case (false, let domain?): return Text("\(byline) · \(Image(systemName: "globe")) \(domain)")
        }
    }

    /// The host without "www.": "dl.acm.org".
    public static func domain(_ url: URL) -> String? {
        guard var host = url.host(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
