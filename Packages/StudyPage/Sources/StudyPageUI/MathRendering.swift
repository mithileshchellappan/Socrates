import StudyPageFormat
import SwiftMath
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Formulas with SwiftMath (MIT; CoreText TeX layout on macOS and iOS): drawn once per (LaTeX,
// size, mode) as a TEMPLATE image, so it tints with the text around it (primary in light and
// dark) and is cached. A formula renders in milliseconds, on the main actor (SwiftMath draws
// with AppKit / UIKit).

@MainActor
enum MathRendering {
    struct Key: Hashable {
        var latex: String
        var size: CGFloat
        var display: Bool
        /// nil: a template image.
        var color: String?
    }

    #if os(macOS)
    typealias PlatformImage = NSImage
    #else
    typealias PlatformImage = UIImage
    #endif

    private static var cache: [Key: PlatformImage] = [:]
    private static var order: [Key] = []
    /// About 50 KB a formula: a few hundred fit well under 8 MB.
    private static let limit = 160

    /// The formula as a template image (or drawn in `color`, a concrete colour, for TextKit), or nil
    /// when SwiftMath cannot read it.
    static func image(_ latex: String, size: CGFloat, display: Bool, color: MTColor? = nil) -> PlatformImage? {
        let key = Key(latex: latex, size: size, display: display, color: color.map { "\($0)" })
        if let cached = cache[key] { return cached }
        let math = MTMathImage(
            latex: latex, fontSize: size, textColor: color ?? .black, labelMode: display ? .display : .text, textAlignment: .left
        )
        let (error, rendered) = math.asImage()
        guard error == nil, let image = rendered, image.size.width > 0, image.size.height > 0 else { return nil }
        #if os(macOS)
        if color == nil { image.isTemplate = true }
        let result = image
        #else
        let result = color == nil ? image.withRenderingMode(.alwaysTemplate) : image
        #endif
        cache[key] = result
        order.append(key)
        if order.count > limit { cache[order.removeFirst()] = nil }
        return result
    }

    /// Whether SwiftMath reads the LaTeX (the figure checker); why not when it does not.
    nonisolated static func problem(_ latex: String) -> String? {
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: latex, error: &error)
        if let error { return "math: \(error.localizedDescription)" }
        if list == nil { return "math: unreadable" }
        return nil
    }
}

/// A formula as text-coloured image (display math centred in its block by the caller).
struct MathImageView: View {
    let latex: String
    let size: CGFloat
    var display = true

    var body: some View {
        if let image = MathRendering.image(latex, size: size, display: display) {
            #if os(macOS)
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .accessibilityLabel(Text(verbatim: InlineMath.spoken(latex)))
            #else
            Image(uiImage: image)
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .accessibilityLabel(Text(verbatim: InlineMath.spoken(latex)))
            #endif
        } else {
            Text(verbatim: InlineMath.unicode(latex) ?? latex)
                .font(.system(size: size - 1, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
