import Capture
import SwiftUI

/// One slide of a deck, drawn from the deck's bitmap cache at a fixed width.
///
/// No spinner: while a bitmap loads the page shows as blank paper (or the thumbnail, scaled
/// up, when only that is ready), then the sharp bitmap replaces it.
public struct SlideImageView: View {
    let deck: SlideDeck
    let page: Int
    let pixelWidth: Int
    let cornerRadius: CGFloat

    @State private var image: CGImage?
    @State private var imagePage: Int?

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
            if let image, imagePage == page {
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
        if let ready = await deck.cachedImage(page: page, width: pixelWidth) {
            show(ready)
            return
        }
        if pixelWidth > SlideWidth.thumbnail,
           let preview = await deck.cachedImage(page: page, width: SlideWidth.thumbnail) {
            show(preview)
        }
        guard !Task.isCancelled, let sharp = try? await deck.image(page: page, width: pixelWidth),
              !Task.isCancelled
        else { return }
        show(sharp)
    }

    private func show(_ image: CGImage) {
        self.image = image
        self.imagePage = page
    }
}
