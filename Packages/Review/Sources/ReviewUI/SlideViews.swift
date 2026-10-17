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
                .padding(.bottom, 64)
            }
            .scrollIndicators(.never)
            .task {
                // The slide the review opens on: once the lazy list has laid out (a scroll asked
                // for while it appears is dropped, as for the transcript).
                try? await Task.sleep(for: .milliseconds(60))
                if let page = model.session.shownPage { proxy.scrollTo(page, anchor: .center) }
            }
            .onChange(of: shown) { _, page in
                guard let page else { return }
                withAnimation(.snappy) { proxy.scrollTo(page, anchor: .center) }
            }
        }
        .accessibilityLabel(Text("Slides"))
    }
}

private struct RailThumbnail: View {
    let deck: SlideDeck
    let page: Int
    let isCurrent: Bool
    let hasNotes: Bool

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
            HStack(spacing: 5) {
                Text(verbatim: "\(page)")
                    .monospacedDigit()
                Spacer(minLength: 0)
                if hasNotes {
                    Image(systemName: "pencil")
                        .imageScale(.small)
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

/// The slide on screen at 2048 px, aspect fit. Prefetches two slides either side so paging never
/// waits for a render.
struct SlideStage: View {
    let model: ReviewModel
    let deck: SlideDeck

    var body: some View {
        let page = model.session.shownPage ?? 1
        SlideBitmapView(deck: deck, page: page)
            .frame(maxWidth: .infinity)
            .task(id: page) {
                await deck.prefetch(pages: [page + 1, page - 1, page + 2, page - 2], width: SlideWidth.display)
            }
    }
}
