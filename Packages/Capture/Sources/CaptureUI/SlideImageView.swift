import Capture
import SwiftUI

/// One slide of a deck, drawn from the deck's bitmap cache at a fixed width.
///
/// No spinner and no blank frame on a slide change: a bitmap already in memory (the deck
/// prefetches the neighbours) is drawn in the same frame the page changes. Otherwise the
/// previous slide stays (or the thumbnail, scaled up, when only that is ready) until the sharp
/// bitmap replaces it; only the very first load shows blank paper.
public struct SlideImageView: View {
    let deck: SlideDeck
    let page: Int
    let pixelWidth: Int
    let cornerRadius: CGFloat

    /// What the last load produced: this page's bitmap or preview, or the previous page's.
    @State private var image: CGImage?

    public init(deck: SlideDeck, page: Int, pixelWidth: Int = SlideWidth.display, cornerRadius: CGFloat = 6) {
        self.deck = deck
        self.page = page
        self.pixelWidth = pixelWidth
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            Color.white
            if let image = deck.cachedImage(page: page, width: pixelWidth) ?? image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            }
        }
        .aspectRatio(deck.aspectRatio(page: page), contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel(Text("Slide \(page)"))
        .accessibilityAddTraits(.isImage)
        .task(id: TaskKey(page: page, width: pixelWidth)) {
            await load()
        }
    }

    private struct TaskKey: Hashable {
        var page: Int
        var width: Int
    }

    private func load() async {
        if let ready = deck.cachedImage(page: page, width: pixelWidth) {
            image = ready
            return
        }
        if pixelWidth > SlideWidth.thumbnail, let preview = deck.cachedImage(page: page, width: SlideWidth.thumbnail) {
            image = preview
        }
        guard !Task.isCancelled, let sharp = try? await deck.image(page: page, width: pixelWidth),
              !Task.isCancelled
        else { return }
        image = sharp
    }
}
