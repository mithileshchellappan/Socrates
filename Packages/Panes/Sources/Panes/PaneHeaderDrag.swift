#if os(macOS)
import AppKit

/// A drag of a pane's header (screen 41): it starts after 4 pt, an image of the header follows the
/// pointer, and exactly one target lights (unanimated) while the pointer is over it. Esc cancels.
@MainActor
enum PaneHeaderDrag {
    /// Follows the press `event` on `header` until the mouse goes up and returns the drop, if the
    /// drag ended over a target. `strip` holds the targets' coordinates, the image and the light.
    static func track(from event: NSEvent, header: NSView, in strip: NSView, targets: [PaneDropTarget]) -> PaneDrop? {
        guard let window = strip.window else { return nil }
        let start = event.locationInWindow
        let grab = header.convert(start, from: nil)
        let highlight = PaneDropHighlight()
        highlight.isHidden = true
        var image: NSImageView?
        var target: PaneDropTarget?
        defer {
            image?.removeFromSuperview()
            highlight.removeFromSuperview()
        }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            switch next.type {
            case .leftMouseDragged:
                let point = next.locationInWindow
                if image == nil {
                    guard hypot(point.x - start.x, point.y - start.y) >= 4 else { continue }
                    strip.addSubview(highlight)
                    image = snapshot(of: header)
                    if let image { strip.addSubview(image) }
                }
                let local = strip.convert(point, from: nil)
                image?.setFrameOrigin(NSPoint(x: local.x - grab.x, y: local.y - grab.y))
                let found = targets.first { $0.area.contains(local) }
                if found != target {
                    target = found
                    if let found { highlight.frame = found.area.insetBy(dx: 3, dy: 3) }
                    highlight.isHidden = found == nil
                }
            case .leftMouseUp:
                return image == nil ? nil : target?.drop
            case .keyDown where next.keyCode == 53:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// The header as an image, a little transparent.
    private static func snapshot(of header: NSView) -> NSImageView? {
        guard let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds) else { return nil }
        header.cacheDisplay(in: header.bounds, to: rep)
        let image = NSImage(size: header.bounds.size)
        image.addRepresentation(rep)
        let view = NSImageView(frame: NSRect(origin: .zero, size: header.bounds.size))
        view.image = image
        view.imageScaling = .scaleNone
        view.alphaValue = 0.85
        return view
    }
}
#endif
