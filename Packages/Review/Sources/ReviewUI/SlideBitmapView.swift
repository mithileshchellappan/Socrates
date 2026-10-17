import Capture
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The large slide (the deck's 2048 px bitmap), drawn into a view's own backing store.
///
/// A `CGImage` handed to Core Animation as layer contents (which is what SwiftUI's `Image` does)
/// is kept by Core Animation well after it is off screen: paging through the 88 slides of DC L2
/// left about 25 decoded 2048 px slides alive, 410 MB in all. Drawn into the backing store, only
/// that one buffer stays (134 MB after the same run; docs/decisions.md). Like CaptureUI's
/// `SlideImageView`, the previous slide stays up until the new bitmap is there (a prefetched one is
/// there in the same frame), so a slide change never flashes blank and never shows a spinner.
struct SlideBitmapView: View {
    let deck: SlideDeck
    let page: Int

    @State private var image: CGImage?

    var body: some View {
        SlideCanvas(image: deck.cachedImage(page: page, width: SlideWidth.display) ?? image)
            .aspectRatio(deck.aspectRatio(page: page), contentMode: .fit)
            .accessibilityElement()
            .accessibilityLabel(Text("Slide \(page)"))
            .accessibilityAddTraits(.isImage)
            .task(id: page) {
                await load()
            }
    }

    private func load() async {
        if let ready = deck.cachedImage(page: page, width: SlideWidth.display) {
            image = ready
            return
        }
        if let preview = deck.cachedImage(page: page, width: SlideWidth.thumbnail) {
            image = preview
        }
        guard !Task.isCancelled, let sharp = try? await deck.image(page: page, width: SlideWidth.display),
              !Task.isCancelled
        else { return }
        image = sharp
    }
}

/// White paper with rounded corners and a hairline edge, the bitmap scaled to fill it (the view
/// already has the slide's aspect ratio).
private enum SlidePaper {
    static let cornerRadius: CGFloat = 6
    static let edge = CGColor(gray: 0, alpha: 0.12)
    static let white = CGColor(gray: 1, alpha: 1)

    static func draw(_ image: CGImage?, in bounds: CGRect, context: CGContext) {
        let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(white)
        context.fill(bounds)
        if let image {
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
        }
        context.restoreGState()
        context.addPath(CGPath(
            roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
        ))
        context.setStrokeColor(edge)
        context.setLineWidth(0.5)
        context.strokePath()
    }
}

#if canImport(AppKit)
private struct SlideCanvas: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> SlideCanvasView {
        SlideCanvasView()
    }

    func updateNSView(_ view: SlideCanvasView, context: Context) {
        view.image = image
    }
}

final class SlideCanvasView: NSView {
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        SlidePaper.draw(image, in: bounds, context: context)
    }
}
#elseif canImport(UIKit)
private struct SlideCanvas: UIViewRepresentable {
    let image: CGImage?

    func makeUIView(context: Context) -> SlideCanvasView {
        SlideCanvasView()
    }

    func updateUIView(_ view: SlideCanvasView, context: Context) {
        view.image = image
    }
}

final class SlideCanvasView: UIView {
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // UIKit's context is flipped; draw the bitmap upright.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        SlidePaper.draw(image, in: bounds, context: context)
        context.restoreGState()
    }
}
#endif
