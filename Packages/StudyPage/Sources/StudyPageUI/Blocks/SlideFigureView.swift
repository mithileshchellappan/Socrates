#if os(macOS)
import Capture
import CaptureUI
import NotesUI
import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

/// A `slide` fence: the lecture's slide on white paper (a hairline and the soft shadow, DESIGN
/// 3.4's one exception) from the slide image cache, the student's own ink drawn over it as Review
/// draws it, Claude's box (where it points) as a faint rounded rect in the AI colour (never ink),
/// then its `SlideChip` and Claude's one-line caption.
struct SlideFigureView: View {
    let deck: Deck
    let page: Int
    let box: NotesSlideBox?
    let caption: String
    let width: CGFloat
    let services: StudyServices?
    let openSlide: () -> Void

    @State private var slides: SlideDeck?
    @State private var ink: InkDrawing?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            paper
                .frame(width: width)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .contentShape(Rectangle())
                .onTapGesture(perform: openSlide)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SlideChip(page: page, action: openSlide)
                if !caption.isEmpty {
                    Text(verbatim: caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: "\(deck.blobSHA256)/\(page)") { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Slide \(page)"))
    }

    @ViewBuilder
    private var paper: some View {
        if let slides {
            SlideImageView(deck: slides, page: page, pixelWidth: Int(width * 2), cornerRadius: 3)
                .overlay {
                    if let ink, !ink.isEmpty { InkView(drawing: ink, surface: .slide) }
                }
                .overlay { AIBox(box: box) }
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        }
    }

    private func load() async {
        guard let services, !deck.blobPath.isEmpty else { return }
        let blob = BlobRef(sha256: deck.blobSHA256, relativePath: deck.blobPath)
        slides = NoteDeckCache.cached(sha: deck.blobSHA256)
        if slides == nil { slides = await NoteDeckCache.deck(blob: blob, services: services) }
        ink = try? await SlideInkRepository(store: services.records).drawing(deckID: deck.id, page: page)
    }
}

/// Claude points at part of the slide: a faint rounded box in the AI colour (decision 7), drawn
/// from the box's fractions of the page, never as ink.
struct AIBox: View {
    let box: NotesSlideBox?

    var body: some View {
        if let box {
            Canvas { context, size in
                let rect = CGRect(
                    x: box.x * size.width, y: box.y * size.height, width: box.width * size.width, height: box.height * size.height
                ).insetBy(dx: -2, dy: -2)
                let shape = Path(roundedRect: rect, cornerRadius: 5)
                context.fill(shape, with: .color(Color.ai.opacity(0.07)))
                context.stroke(shape, with: .color(Color.ai.opacity(0.55)), lineWidth: 1.25)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
