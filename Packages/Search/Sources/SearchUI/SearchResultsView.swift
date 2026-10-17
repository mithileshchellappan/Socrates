import Capture
import Search
import StudyCore
import StudyUI
import SwiftUI

/// The search screen (mockup 07 without tutor, "Also searched" and web): All | Lectures | Notes
/// and a course scope above the hits, grouped by course and lecture, notes last, on one surface
/// that scrolls under the toolbar.
///
/// The query comes from the window's search field; ↩ there opens the selected (else first) hit.
/// In the results: ↑/↓ select, ↩ or a double click opens the hit, Space plays it. The selected
/// hit sits on a neutral block. A group with only weak matches (not every word) collapses to its
/// header while others match fully; clicking it opens it. An empty query shows nothing; no hits
/// shows the system's no-results title. Results follow the index: a lecture processed or a note
/// saved while the screen is open shows up. Opening a hit, or ↩ in the field, records the query
/// in `RecentSearches`.
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
    /// Collapsed groups (weak matches only) the student opened, for this query.
    @State private var expanded: Set<SearchGroup.ID> = []
    /// Slide PDFs opened for thumbnails (off the main actor, once per deck for the screen's life);
    /// a slide hit shows its thumbnail once its deck is open.
    @State private var decks: [Deck.ID: SlideDeck] = [:]
    @FocusState private var resultsFocused: Bool
    @AppStorage(RecentSearches.storageKey) private var recentSearches = ""

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
            .screenTitle(String(localized: "Search"), subtitle: subtitle, leadingInset: ScreenTitleInset.firstItem)
            .task(id: SearchKey(query: searchQuery, chunks: chunkCount, indexedAt: indexedAt)) {
                await search()
            }
            .onChange(of: submits) {
                // Keyboard-first from the toolbar field: ↩ opens the hit without reaching for the list.
                recordQuery()
                if let results, let hit = selection.flatMap(results.hit(id:)) ?? visibleHits(results).first {
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
            ScrollViewReader { proxy in
                // Filters and hits share one surface that scrolls under the toolbar (no title bar
                // line), as in the mockup.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        filters
                            .id(RowID.filters)
                        if let results {
                            // Until the next search lands (milliseconds) the previous results stay.
                            ForEach(rows(results)) { row in
                                rowView(row, results)
                            }
                        }
                    }
                    .padding(.leading, SearchMetrics.margin)
                    .padding(.trailing, SearchMetrics.trailingMargin)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
                .focusable()
                .focused($resultsFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    moveSelection(by: press.key == .upArrow ? -1 : 1, proxy: proxy) ? .handled : .ignored
                }
                .onKeyPress(.return) {
                    guard let hit = selectedHit, hit.destination != nil else { return .ignored }
                    open(hit)
                    return .handled
                }
                .onKeyPress(.space) {
                    guard let hit = selectedHit, hit.playDestination != nil else { return .ignored }
                    play(hit)
                    return .handled
                }
                .onChange(of: query) {
                    proxy.scrollTo(RowID.filters, anchor: .top)
                }
                .overlay {
                    if let results, results.isEmpty {
                        ContentUnavailableView("No Results for “\(query)”", systemImage: "magnifyingglass")
                    }
                }
            }
        }
    }

    /// "8 results".
    private var subtitle: String {
        guard !searchQuery.isEmpty, let results else { return "" }
        return String(AttributedString(localized: "^[\(results.count) result](inflect: true)").characters)
    }

    // MARK: - Filters

    private var filters: some View {
        HStack(spacing: 6) {
            FilterSegments(selection: $scope, label: "Show", options: [
                .init(value: .all, title: "All"),
                .init(value: .lectures, title: "Lectures"),
                .init(value: .notes, title: "Notes")
            ])
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
                // Quiet, as in the mockup: secondary text and a thin chevron, no bezel.
                HStack(spacing: 3) {
                    Text(courses.first { $0.id == courseID }?.name ?? String(localized: "All courses"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .regular))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Rows

    /// The screen's rows, flat so the stack stays lazy: each group's header, then its hits.
    private enum Row: Identifiable {
        case header(SearchGroup, collapsedLabel: String?)
        case hit(SearchHit, firstInGroup: Bool)

        var id: RowID {
            switch self {
            case .header(let group, _): .header(group.id)
            case .hit(let hit, _): .hit(hit.id)
            }
        }
    }

    private enum RowID: Hashable {
        case filters
        case header(SearchGroup.ID)
        case hit(SearchHit.ID)
    }

    private func rows(_ results: SearchResults) -> [Row] {
        var rows: [Row] = []
        for group in results.groups {
            if isCollapsed(group, in: results) {
                rows.append(.header(group, collapsedLabel: group.hits.first.map(results.label(for:)) ?? ""))
            } else {
                rows.append(.header(group, collapsedLabel: nil))
                for (index, hit) in group.hits.enumerated() {
                    rows.append(.hit(hit, firstInGroup: index == 0))
                }
            }
        }
        return rows
    }

    private func isCollapsed(_ group: SearchGroup, in results: SearchResults) -> Bool {
        results.collapses(group, expanded: expanded)
    }

    /// The hits shown (not in a collapsed group), in order.
    private func visibleHits(_ results: SearchResults) -> [SearchHit] {
        results.visibleHits(expanded: expanded)
    }

    private var selectedHit: SearchHit? {
        guard let results, let selection else { return nil }
        return results.hit(id: selection)
    }

    @ViewBuilder
    private func rowView(_ row: Row, _ results: SearchResults) -> some View {
        switch row {
        case .header(let group, let collapsedLabel):
            Group {
                if let collapsedLabel {
                    Button {
                        expanded.insert(group.id)
                    } label: {
                        SearchGroupHeader(group: group, collapsedLabel: collapsedLabel)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    SearchGroupHeader(group: group)
                }
            }
            .padding(.top, SearchMetrics.groupSpacing)
            .id(row.id)
        case .hit(let hit, let firstInGroup):
            hitRow(hit, results)
                .padding(.top, firstInGroup ? 4 : 0)
                .id(row.id)
        }
    }

    private func hitRow(_ hit: SearchHit, _ results: SearchResults) -> some View {
        let isSelected = selection == hit.id
        return SearchHitRow(
            hit: hit,
            label: results.label(for: hit),
            deck: thumbnailDeck(hit),
            play: { play(hit) }
        )
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: SearchMetrics.selectionRadius, style: .continuous)
                    .fill(QuietFill())
            }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { open(hit) }
        .simultaneousGesture(TapGesture().onEnded {
            selection = hit.id
            resultsFocused = true
        })
        .contextMenu {
            Button("Open") { open(hit) }
                .disabled(hit.destination == nil)
            if hit.playDestination != nil {
                Button("Play") { play(hit) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open(hit) }
        .accessibilityActions {
            if hit.playDestination != nil {
                Button("Play") { play(hit) }
            }
        }
    }

    /// Moves the selection through the shown hits; the first hit of a group brings its header
    /// (the first of all, the filters) into view with it.
    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> Bool {
        guard let results else { return false }
        let visible = visibleHits(results)
        guard !visible.isEmpty else { return false }
        let current = selection.flatMap { id in visible.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + offset, 0), visible.count - 1) } ?? 0
        let hit = visible[next]
        selection = hit.id
        if next == 0 {
            proxy.scrollTo(RowID.filters)
        } else if let group = results.groups.first(where: { $0.hits.first?.id == hit.id }) {
            proxy.scrollTo(RowID.header(group.id))
        } else {
            proxy.scrollTo(RowID.hit(hit.id))
        }
        return true
    }

    private func thumbnailDeck(_ hit: SearchHit) -> SlideDeck? {
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

    // MARK: - Actions

    private func open(_ hit: SearchHit) {
        guard let destination = hit.destination else { return }
        recordQuery()
        openDestination(destination)
    }

    private func play(_ hit: SearchHit) {
        guard let destination = hit.playDestination else { return }
        recordQuery()
        openDestination(destination)
    }

    /// Puts the query first among the sidebar's recent searches.
    private func recordQuery() {
        var recent = RecentSearches(storage: recentSearches)
        recent.record(query)
        recentSearches = recent.storage
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
            if found.query.text != results?.query.text { expanded = [] }
            results = found
            let visible = visibleHits(found)
            if selection.flatMap({ id in visible.first { $0.id == id } }) == nil { selection = visible.first?.id }
            if opensFirstHit {
                opensFirstHit = false
                if let hit = visible.first { open(hit) }
            }
            await openDecks(for: found)
        } catch {
            Log.search.error("Search failed: \(String(describing: error), privacy: .public)")
        }
    }
}
