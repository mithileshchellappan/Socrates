#if os(macOS)
import Capture
import CaptureUI
import NotesUI
import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

/// A `slide` fence: the lecture's slide on white paper (a hairline and the soft shadow, DESIGN
/// 3.4's one exception) from the slide image cache, Claude's box (where it points) as a faint
/// rounded rect in the AI colour (never ink), then its `SlideChip` under its leading edge and
/// Claude's one-line caption.
///
/// nl (docs/plan-notes-layout.md §3, §5): at most `maxWidth` wide (the page: 640 × zoom, centred
/// in the page's full width; Review's pane: 296), narrower when its line is. The student's ink is
/// never drawn on the slides inside Claude's text (`showsInk` false): it shows in Your notes, whose
/// thumbnails are this view with `showsInk` and without the chip and caption.
struct SlideFigureView: View {
    let deck: Deck
    let page: Int
    /// The widest it is drawn.
    let maxWidth: CGFloat
    /// Centred in its line (the page's breakout), else from its leading edge.
    var centred = false
    var box: NotesSlideBox?
    var caption: String = ""
    /// The chip and caption under the slide (off for Your notes' thumbnails).
    var showsChip = true
    /// The student's ink over the slide (Your notes' thumbnails only).
    var showsInk = false
    /// The drawing to show (Your notes passes its observed rows); nil with `showsInk`: read once.
    var ink: InkDrawing?
    /// The notes' content zoom (the chip and caption).
    var zoom: CGFloat = 1
    let services: StudyServices?
    let openSlide: () -> Void

    @State private var slides: SlideDeck?
    @State private var loadedInk: InkDrawing?

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * zoom) {
            paper
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .contentShape(Rectangle())
                .onTapGesture(perform: openSlide)
            if showsChip {
                HStack(alignment: .firstTextBaseline, spacing: 8 * zoom) {
                    NotesChip(text: "S\(page)", size: 10.5 * zoom, action: openSlide)
                    if !caption.isEmpty {
                        Text(verbatim: caption)
                            .font(.system(size: 12 * zoom))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
        .task(id: "\(deck.blobSHA256)/\(page)/\(showsInk)") { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Slide \(page)"))
    }

    @ViewBuilder
    private var paper: some View {
        if let slides {
            SlideImageView(deck: slides, page: page, pixelWidth: Self.pixelWidth(maxWidth), cornerRadius: 3)
                .overlay {
                    if showsInk, let drawing = ink ?? loadedInk, !drawing.isEmpty { InkView(drawing: drawing, surface: .slide) }
                }
                .overlay { AIBox(box: box) }
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        }
    }

    /// The bitmap's width for a slide at most `points` wide at 2× (a multiple of 128, so the
    /// zoom steps share a few cached sizes).
    static func pixelWidth(_ points: CGFloat) -> Int {
        let pixels = Int((points * 2).rounded(.up))
        return min(SlideWidth.display, max(SlideWidth.thumbnail, ((pixels + 127) / 128) * 128))
    }

    private func load() async {
        guard let services, !deck.blobPath.isEmpty else { return }
        let blob = BlobRef(sha256: deck.blobSHA256, relativePath: deck.blobPath)
        slides = NoteDeckCache.cached(sha: deck.blobSHA256)
        if slides == nil { slides = await NoteDeckCache.deck(blob: blob, services: services) }
        if showsInk, ink == nil {
            loadedInk = try? await SlideInkRepository(store: services.records).drawing(deckID: deck.id, page: page)
        }
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
