import PDFKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A previewed drag's file under the cursor (mockup 10), for parity screenshots and snapshots
/// only: during a real drag the system draws the dragged file and its + badge. The deck's first
/// page as a 168 pt card at 90 % (3 pt corners, a lifted shadow), its name in an accent capsule
/// 7 pt below, the arrow cursor on the card and the green copy badge at the cursor.
struct DropGhostPreview: View {
    let ghost: FilingCenter.DragGhost
    /// The cursor's tip, in the smart-import coordinate space.
    let location: CGPoint
    @State private var thumbnail: Image?

    static let width: CGFloat = 168
    /// Where the tip sits on the card (mockup 10: near its lower right).
    static let tip = CGSize(width: 132, height: 65)

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 7) {
                card
                Text(verbatim: ghost.fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.92), in: .rect(cornerRadius: 4, style: .continuous))
            }
            .frame(width: Self.width)
            .offset(x: location.x - Self.tip.width, y: location.y - Self.tip.height)
            cursor
            Circle()
                .fill(Color.green)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                .frame(width: 16, height: 16)
                .offset(x: location.x + 10, y: location.y + 18)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: ghost.url) { thumbnail = Self.firstPage(of: ghost.url) }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return Group {
            if let thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white.aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .frame(width: Self.width)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .opacity(0.9)
        .shadow(color: .black.opacity(0.3), radius: 16, y: 12)
    }

    @ViewBuilder
    private var cursor: some View {
        #if canImport(AppKit)
        let arrow = NSCursor.arrow
        Image(nsImage: arrow.image)
            .offset(x: location.x - arrow.hotSpot.x, y: location.y - arrow.hotSpot.y)
        #endif
    }

    /// The PDF's first page at twice the card's width.
    private static func firstPage(of url: URL) -> Image? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let size = CGSize(width: width * 2, height: width * 2 * 9 / 16)
        #if canImport(AppKit)
        return Image(nsImage: page.thumbnail(of: size, for: .mediaBox))
        #else
        return Image(uiImage: page.thumbnail(of: size, for: .mediaBox))
        #endif
    }
}
