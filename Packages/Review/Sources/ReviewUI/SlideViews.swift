import Capture
import CaptureUI
import Review
import StudyCore
import SwiftUI

/// The rail of 320 px thumbnails: page number, a pencil when the slide has notes, the slide on
/// screen outlined. A click shows that slide paused at its first visit (Follow off).
struct SlideRail: View {
    static let width: CGFloat = 96

    let model: ReviewModel
    let deck: SlideDeck

    private let notesQuery: FetchAll<Note>
    private var notes: [Note] { notesQuery.wrappedValue }

    init(model: ReviewModel, deck: SlideDeck) {
        self.model = model
        self.deck = deck
        let lectureID = model.lecture.id
        notesQuery = FetchAll(Note.where { $0.lectureID.eq(lectureID) }, database: model.services.database)
    }

    var body: some View {
        let shown = model.session.shownPage
        let noted = Set(notes.filter { !$0.isBlank }.compactMap(\.pageNumber))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(1...max(1, deck.pageCount), id: \.self) { page in
                        RailThumbnail(deck: deck, page: page, isCurrent: page == shown, hasNotes: noted.contains(page))
                            .id(page)
                            .onTapGesture {
                                Task { await model.session.selectThumbnail(page: page) }
                            }
                    }
                }
            }
            .scrollIndicators(.never)
            // No hard edge line or blur band where scrolled thumbnails meet the toolbar.
            .scrollEdgeEffectHidden(true, for: .top)
            .fadesAbovePlayer(model.player != nil)
            .task {
                // The slide the review opens on: once the lazy list has laid out (a scroll asked
                // for while it appears is dropped, as for the transcript).
                try? await Task.sleep(for: .milliseconds(60))
                if let page = model.session.shownPage { scroll(proxy, to: page) }
            }
            .onChange(of: shown) { _, page in
                guard let page else { return }
                withAnimation(.snappy) { scroll(proxy, to: page) }
            }
        }
        .accessibilityLabel(Text("Slides"))
    }

    /// The slide on screen as the fourth thumbnail, with three whole ones above it (the first
    /// slides from the top).
    private func scroll(_ proxy: ScrollViewProxy, to page: Int) {
        proxy.scrollTo(max(1, page - Self.thumbnailsAbove), anchor: .top)
    }

    static let thumbnailsAbove = 3
}

private struct RailThumbnail: View {
    let deck: SlideDeck
    let page: Int
    let isCurrent: Bool
    let hasNotes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SlideImageView(deck: deck, page: page, pixelWidth: SlideWidth.thumbnail, cornerRadius: 3)
                .background {
                    // Paper depth (mockup: 0 1px 3px at 18 %).
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                }
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 2.5)
                            .padding(-1.25)
                    }
                }
            HStack(spacing: 5) {
                Text(verbatim: "\(page)")
                    .monospacedDigit()
                Spacer(minLength: 0)
                if hasNotes {
                    // The mockup's 11 pt outline pencil (at caption size SF's reads as a slash).
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .accessibilityLabel(Text("Notes"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(minHeight: 14)
        }
        .padding(6)
        .background(
            isCurrent ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Slide \(page)"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

/// The slide on screen at 2048 px, aspect fit, with its pins in an overlay (M4). Prefetches two
/// slides either side so paging never waits for a render.
struct SlideStage: View {
    let model: ReviewModel
    let deck: SlideDeck

    var body: some View {
        let page = model.session.shownPage ?? 1
        SlideBitmapView(deck: deck, page: page)
            .background {
                // The canvas cannot draw outside its bounds: the paper's shadow is SwiftUI's.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            }
            // Over the bitmap, in the slide's own frame: the bitmap is never redrawn for them.
            .overlay {
                SlidePins(model: model, page: page)
            }
            .frame(maxWidth: .infinity)
            .task(id: page) {
                await deck.prefetch(pages: [page + 1, page - 1, page + 2, page - 2], width: SlideWidth.display)
            }
    }
}
