import Capture
import Search
import StudyCore
import StudyUI
import SwiftUI

/// The search screen (mockup 07 without tutor, "Also searched" and web): All | Lectures | Notes
/// and a course scope above the hits, grouped by course and lecture, notes last.
///
/// The query comes from the window's search field; ↩ there opens the selected (else first) hit.
/// In the list: ↑/↓ select, ↩ opens the hit, Space plays it. An empty query shows nothing; no hits shows the system's no-results view.
/// Results follow the index: a lecture processed or a note saved while the screen is open shows up.
public struct SearchResultsView: View {
    private let query: String
    /// Counts ↩ presses in the window's search field: each opens the selected (or first) hit.
    private let submits: Int
    /// ↩ came before the results: open the first hit when they land.
    @State private var opensFirstHit = false

    @State private var scope: SearchQuery.Scope = .all
    @State private var courseID: Course.ID?
    @State private var results: SearchResults?
    @State private var selection: SearchHit.ID?
    /// Slide PDFs opened for thumbnails (off the main actor, once per deck for the screen's life);
    /// a slide hit shows its thumbnail once its deck is open.
    @State private var decks: [Deck.ID: SlideDeck] = [:]

    @FetchAll(Course.order { ($0.sortOrder, $0.name) }) private var courses
    @FetchOne(SearchChunk.select { $0.count() }) private var chunkCount = 0
    @FetchOne(SearchChunk.select { $0.updatedAt.max() }) private var indexedAt: Date? = nil
    @Dependency(\.defaultDatabase) private var database
    @Environment(\.openDestination) private var openDestination
    @Environment(\.studyServices) private var services

    public init(query: String, submits: Int = 0) {
        self.query = query
        self.submits = submits
    }

    private var searchQuery: SearchQuery {
        SearchQuery(query, scope: scope, courseID: courseID)
    }

    private struct SearchKey: Hashable {
        var query: SearchQuery
        var chunks: Int
        var indexedAt: Date?
    }

    public var body: some View {
        content
            .navigationTitle("Search")
            #if os(macOS)
            .navigationSubtitle(subtitle)
            #endif
            .task(id: SearchKey(query: searchQuery, chunks: chunkCount, indexedAt: indexedAt)) {
                await search()
            }
            .onChange(of: submits) {
                // Keyboard-first from the toolbar field: ↩ opens the hit without reaching for the list.
                if let results, let hit = selection.flatMap(results.hit(id:)) ?? results.hits.first {
                    open(hit)
                } else {
                    opensFirstHit = true
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if searchQuery.isEmpty {
            Color.clear
        } else {
            VStack(spacing: 0) {
                filters
                if let results {
                    // Until the next search lands (milliseconds) the previous results stay.
                    if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxHeight: .infinity)
                    } else {
                        list(results)
                    }
                } else {
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var subtitle: Text {
        guard !searchQuery.isEmpty, let results else { return Text(verbatim: "") }
        return Text("^[\(results.count) result](inflect: true)")
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("Show", selection: $scope) {
                Text("All").tag(SearchQuery.Scope.all)
                Text("Lectures").tag(SearchQuery.Scope.lectures)
                Text("Notes").tag(SearchQuery.Scope.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            Menu {
                Picker("Course", selection: $courseID) {
                    Text("All courses").tag(Course.ID?.none)
                    Divider()
                    ForEach(courses) { course in
                        Text(course.name).tag(Course.ID?.some(course.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(courses.first { $0.id == courseID }?.name ?? String(localized: "All courses"))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func list(_ results: SearchResults) -> some View {
        List(selection: $selection) {
            ForEach(results.groups) { group in
                Section {
                    ForEach(group.hits) { hit in
                        SearchHitRow(
                            hit: hit,
                            label: results.label(for: hit),
                            deck: thumbnailDeck(hit, results),
                            play: { play(hit) }
                        )
                        .tag(hit.id)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    SearchGroupHeader(group: group)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        // Filters and hits share one surface, as in the mockup.
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: SearchHit.ID.self) { ids in
            if let id = ids.first, let hit = results.hit(id: id) {
                Button("Open") { open(hit) }
                    .disabled(hit.destination == nil)
                if hit.playDestination != nil {
                    Button("Play") { play(hit) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let hit = results.hit(id: id) { open(hit) }
        }
        .onKeyPress(.space) {
            guard let id = selection, let hit = results.hit(id: id), hit.playDestination != nil else { return .ignored }
            play(hit)
            return .handled
        }
        .onKeyPress(.return) {
            guard let id = selection, let hit = results.hit(id: id), hit.destination != nil else { return .ignored }
            open(hit)
            return .handled
        }
    }

    private func thumbnailDeck(_ hit: SearchHit, _ results: SearchResults) -> SlideDeck? {
        guard hit.kind == .slide, let deckID = hit.deckID else { return nil }
        return decks[deckID]
    }

    /// Opens the decks of the slide hits that are not open yet, off the main actor.
    private func openDecks(for results: SearchResults) async {
        guard let services else { return }
        var seen = Set(decks.keys)
        for hit in results.hits where hit.kind == .slide {
            guard let deckID = hit.deckID, seen.insert(deckID).inserted, let deck = results.decks[deckID] else { continue }
            guard let opened = await SlideDeckOpener.open(deck, services: services), !Task.isCancelled else { continue }
            decks[deckID] = opened
        }
    }

    private func open(_ hit: SearchHit) {
        if let destination = hit.destination { openDestination(destination) }
    }

    private func play(_ hit: SearchHit) {
        if let destination = hit.playDestination { openDestination(destination) }
    }

    private func search() async {
        let query = searchQuery
        guard !query.isEmpty else {
            results = nil
            return
        }
        do {
            let found = try await SearchEngine(database: database).search(query)
            guard !Task.isCancelled else { return }
            results = found
            if selection.flatMap(found.hit(id:)) == nil { selection = found.hits.first?.id }
            if opensFirstHit {
                opensFirstHit = false
                if let hit = found.hits.first { open(hit) }
            }
            await openDecks(for: found)
        } catch {
            Log.search.error("Search failed: \(String(describing: error), privacy: .public)")
        }
    }
}
