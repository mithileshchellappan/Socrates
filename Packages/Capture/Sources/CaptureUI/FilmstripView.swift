import Capture
import SwiftUI

/// Thumbnails of the deck around the slide on screen; click one to jump there (stamped while
/// recording). Slides after the current one are dimmed. The strip keeps the current slide
/// about two thirds across, so more of what was shown than what is coming stays visible.
struct FilmstripView: View {
    let session: LiveLectureSession
    let deck: SlideDeck

    @State private var position = ScrollPosition(edge: .leading)
    @State private var viewportWidth: CGFloat = 0

    private static let thumbnailWidth: CGFloat = 92
    private static let itemPadding: CGFloat = 6
    private static let spacing: CGFloat = 6
    private static let inset: CGFloat = 16
    private static var stride: CGFloat { thumbnailWidth + 2 * itemPadding + spacing }

    var body: some View {
        let current = session.currentPage
        ScrollView(.horizontal) {
            LazyHStack(spacing: Self.spacing) {
                ForEach(1...max(1, session.pageCount), id: \.self) { page in
                    Button {
                        session.jump(to: page)
                    } label: {
                        FilmstripThumbnail(
                            deck: deck, page: page, width: Self.thumbnailWidth, padding: Self.itemPadding,
                            isCurrent: page == current, isLater: page > current
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Self.inset)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            viewportWidth = width
            position.scrollTo(x: offset(for: current, viewport: width))
        }
        .onChange(of: current) { _, page in
            withAnimation(.snappy) {
                position.scrollTo(x: offset(for: page, viewport: viewportWidth))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // The inset stays empty while scrolled: the thumbnail before the first whole one does
        // not peek out (mockup 02's grid: tiles from 16 pt, images from 22 pt).
        .overlay(alignment: .leading) {
            Color.contentBackground
                .frame(width: Self.inset)
                .allowsHitTesting(false)
        }
        // The strip ends at the main column; nothing scrolls on under the inspector.
        .clipped()
        .background(Color.contentBackground)
    }

    /// Scroll offset that puts the centre of `page` at about 65 % of the visible width, rounded
    /// down to a whole thumbnail so the strip starts with a whole one at the inset, on the same
    /// grid as the unscrolled strip.
    private func offset(for page: Int, viewport: CGFloat) -> CGFloat {
        Self.offset(for: page, pageCount: session.pageCount, viewport: viewport)
    }

    static func offset(for page: Int, pageCount: Int, viewport: CGFloat) -> CGFloat {
        let center = inset + CGFloat(page - 1) * stride + (stride - spacing) / 2
        let content = 2 * inset + CGFloat(max(1, pageCount)) * stride - spacing
        let maxOffset = max(0, content - viewport)
        let first = ((center - viewport * 0.65) / stride).rounded(.down)
        guard first >= 1 else { return 0 }
        // The first whole thumbnail's tile at the inset; the inset's overlay hides the one before.
        return min(maxOffset, first * stride)
    }
}

private struct FilmstripThumbnail: View {
    let deck: SlideDeck
    let page: Int
    let width: CGFloat
    let padding: CGFloat
    let isCurrent: Bool
    let isLater: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SlideImageView(deck: deck, page: page, pixelWidth: SlideWidth.thumbnail, cornerRadius: 3)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 2.5)
                            .padding(-1.25)
                    }
                }
            Text("\(page)")
                .font(.system(size: 10.5, weight: isCurrent ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .frame(width: width)
        .padding(padding)
        .background(
            isCurrent ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .opacity(isLater ? 0.5 : 1)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(Text("Slide \(page)"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
