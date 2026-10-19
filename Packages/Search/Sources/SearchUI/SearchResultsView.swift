import Capture
import Search
import StudyCore
import StudyUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The search screen (mockup 07): "Also searched" (M5), All | Lectures | Notes | Mail | Web and a
/// course scope above the hits, grouped by course and lecture, then notes, the web and mail, on
/// one surface that scrolls under the toolbar. The tutor (M5) sits in the window's inspector and
/// sees the selected hits through `context`.
///
/// The query comes from the window's search field; ↩ there opens the selected (else first) hit
/// and asks the planner at once. In the results: a click selects one hit, ⌘-click toggles one,
/// ⇧-click extends from the last clicked; ↑/↓ move a single selection; ↩ or a double click
/// opens, Space plays; a web row opens its page on click. Selected hits share one neutral block.
/// A group with only weak matches (not every word) collapses to its header while others match
/// fully; clicking it opens it. An empty query shows nothing; no hits shows the system's
/// no-results title. Results follow the index. Opening a hit, or ↩ in the field, records the
/// query in `RecentSearches`.
///
/// Keyword (and, with `\.searchProviders`, semantic) results show at once; the planner's
/// alternatives ("Also searched", cached in `search_plan`) fuse in when they land.
public struct SearchResultsView: View {
    private let query: String
    /// Counts ↩ presses in the window's search field: each opens the selected (or first) hit.
    private let submits: Int
    /// The tutor's context: `.search(query:sources:)` with the selected hits (never mail).
    @Binding private var context: ChatContext
    /// ↩ came before the results: open the first hit when they land.
    @State private var opensFirstHit = false

    @State private var scope: SearchQuery.Scope = .all
    @State private var courseID: Course.ID?
    @State private var results: SearchResults?
    @State private var plan = QueryPlanState()
    /// The selected hits (shown, never in a collapsed group).
    @State private var selection: Set<SearchHit.ID> = []
    /// The hit ↑/↓, ↩ and Space start from, and ⇧-click extends from.
    @State private var cursor: SearchHit.ID?
    /// The selection is the screen's default (the first group's best hits), not the student's:
    /// it follows the results.
    @State private var selectionIsDefault = true
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
    @Environment(\.openURL) private var openURL
    @Environment(\.studyServices) private var services
    @Environment(\.searchProviders) private var providers

    /// At most this many hits are selected by default (the first group's).
    static let defaultSelectionLimit = 4
    /// How long keyword hits wait for the semantic list on a keystroke.
    static let semanticWait: Duration = .milliseconds(100)

    public init(query: String, submits: Int = 0, context: Binding<ChatContext> = .constant(.none)) {
        self.query = query
        self.submits = submits
        _context = context
    }

    private var engine: SearchEngine {
        SearchEngine(database: database, planner: providers.planner, semantic: providers.semantic)
    }

    private var searchQuery: SearchQuery {
        SearchQuery(query, scope: scope, courseID: courseID, alternatives: plan.query == query ? plan.shown : [])
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
            .task(id: query) {
                plan.follow(query, courseID: courseID, engine: engine)
            }
            .task {
                // The model loads while the student types (it unloads after 2 min without queries).
                if let index = providers.semantic as? SemanticIndex { await index.warm() }
            }
            .onDisappear { plan.stop() }
            .onChange(of: submits) {
                // Keyboard-first from the toolbar field: ↩ opens the hit without reaching for the list.
                recordQuery()
                plan.submit(courseID: courseID, engine: engine)
                if let results, let hit = primaryHit ?? visibleHits(results).first {
                    open(hit)
                } else {
                    opensFirstHit = true
                }
            }
            .onChange(of: sources, initial: true) {
                context = .search(query: query, sources: sources)
            }
            .onChange(of: query) {
                context = .search(query: query, sources: sources)
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
                        if let alternatives = results?.alternatives, !alternatives.isEmpty {
                            AlsoSearchedLine(terms: alternatives) { plan.remove($0) }
                                .padding(.bottom, SearchMetrics.alsoSearchedSpacing)
                                .id(RowID.alsoSearched)
                        }
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
                    guard let hit = primaryHit, hit.url != nil || hit.destination != nil else { return .ignored }
                    open(hit)
                    return .handled
                }
                .onKeyPress(.space) {
                    guard let hit = primaryHit, hit.kind != .furtherReading, hit.playDestination != nil else { return .ignored }
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

    /// "8 results"; nothing at 0 ("No Results for …" says it).
    private var subtitle: String {
        guard !searchQuery.isEmpty, let results, results.count > 0 else { return "" }
        return String(AttributedString(localized: "^[\(results.count) result](inflect: true)").characters)
    }

    // MARK: - Filters

    private var filters: some View {
        HStack(spacing: 6) {
            FilterSegments(selection: $scope, label: "Show", options: [
                .init(value: .all, title: "All"),
                .init(value: .lectures, title: "Lectures"),
                .init(value: .notes, title: "Notes"),
                .init(value: .mail, title: "Mail"),
                .init(value: .web, title: "Web")
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
        /// `joinsAbove` / `joinsBelow`: the neighbouring row is a selected hit too (one block).
        case hit(SearchHit, firstInGroup: Bool, joinsAbove: Bool, joinsBelow: Bool)

        var id: RowID {
            switch self {
            case .header(let group, _): .header(group.id)
            case .hit(let hit, _, _, _): .hit(hit.id)
            }
        }
    }

    private enum RowID: Hashable {
        case alsoSearched
        case filters
        case header(SearchGroup.ID)
        case hit(SearchHit.ID)
    }

    private func rows(_ results: SearchResults) -> [Row] {
        var rows: [Row] = []
        for group in results.groups {
            if isCollapsed(group, in: results) {
                // Mail collapses to its best message's subject (mockup 07).
                let first = group.hits.first
                let label = group.kind == .mail ? first?.title : first.map(results.label(for:))
                rows.append(.header(group, collapsedLabel: label ?? ""))
            } else {
                rows.append(.header(group, collapsedLabel: nil))
                for (index, hit) in group.hits.enumerated() {
                    let selected = selection.contains(hit.id)
                    let above = index > 0 && selection.contains(group.hits[index - 1].id)
                    let below = index + 1 < group.hits.count && selection.contains(group.hits[index + 1].id)
                    rows.append(.hit(hit, firstInGroup: index == 0, joinsAbove: selected && above, joinsBelow: selected && below))
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

    /// The hit ↩ and Space act on: the cursor while selected, else the first selected one.
    private var primaryHit: SearchHit? {
        guard let results else { return nil }
        if let cursor, selection.contains(cursor), let hit = results.hit(id: cursor) { return hit }
        return visibleHits(results).first { selection.contains($0.id) }
    }

    /// The selected hits as the tutor's sources, in screen order; never mail or documents.
    private var sources: [ChatSource] {
        guard let results else { return [] }
        return visibleHits(results).filter { selection.contains($0.id) }.compactMap(\.chatSource)
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
        case .hit(let hit, let firstInGroup, let joinsAbove, let joinsBelow):
            hitRow(hit, results, joinsAbove: joinsAbove, joinsBelow: joinsBelow)
                .padding(.top, firstInGroup ? 4 : 0)
                .id(row.id)
        }
    }

    private func hitRow(_ hit: SearchHit, _ results: SearchResults, joinsAbove: Bool, joinsBelow: Bool) -> some View {
        let isSelected = selection.contains(hit.id)
        return Group {
            if hit.kind == .furtherReading {
                WebHitRow(hit: hit)
            } else {
                SearchHitRow(
                    hit: hit,
                    label: results.label(for: hit),
                    deck: thumbnailDeck(hit),
                    play: { play(hit) }
                )
            }
        }
        .background {
            if isSelected {
                // Consecutive selected hits share one block (mockup `.selblock`).
                let radius = SearchMetrics.selectionRadius
                UnevenRoundedRectangle(
                    topLeadingRadius: joinsAbove ? 0 : radius, bottomLeadingRadius: joinsBelow ? 0 : radius,
                    bottomTrailingRadius: joinsBelow ? 0 : radius, topTrailingRadius: joinsAbove ? 0 : radius,
                    style: .continuous
                )
                .fill(QuietFill())
            }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            // A web row's single click already opened its page.
            if hit.kind != .furtherReading { open(hit) }
        }
        .simultaneousGesture(TapGesture().onEnded {
            click(hit, in: results)
            resultsFocused = true
        })
        .contextMenu {
            Button("Open") { open(hit) }
                .disabled(hit.url == nil && hit.destination == nil)
            if hit.kind != .furtherReading, hit.playDestination != nil {
                Button("Play") { play(hit) }
            }
        }
        #if os(macOS)
        .pointerStyle(hit.kind == .furtherReading && hit.url != nil ? .link : .default)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open(hit) }
        .accessibilityActions {
            if hit.kind != .furtherReading, hit.playDestination != nil {
                Button("Play") { play(hit) }
            }
        }
    }

    // MARK: - Selection

    /// A click selects the hit alone, ⌘-click toggles it, ⇧-click selects the shown hits from the
    /// last clicked one to it. A web row also opens its page (a plain click).
    private func click(_ hit: SearchHit, in results: SearchResults) {
        selectionIsDefault = false
        let modifiers = Self.clickModifiers
        if modifiers.contains(.command) {
            if selection.contains(hit.id) {
                selection.remove(hit.id)
            } else {
                selection.insert(hit.id)
            }
            cursor = hit.id
            return
        }
        if modifiers.contains(.shift), let anchor = cursor ?? selection.first {
            let visible = visibleHits(results).map(\.id)
            if let from = visible.firstIndex(of: anchor), let to = visible.firstIndex(of: hit.id) {
                selection = Set(visible[min(from, to)...max(from, to)])
                return
            }
        }
        selection = [hit.id]
        cursor = hit.id
        if hit.kind == .furtherReading { open(hit) }
    }

    /// The keyboard modifiers held during a click (macOS; none elsewhere).
    private static var clickModifiers: EventModifiers {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
        #else
        return []
        #endif
    }

    /// Moves a single selection through the shown hits; the first hit of a group brings its
    /// header (the first of all, the filters) into view with it.
    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> Bool {
        guard let results else { return false }
        let visible = visibleHits(results)
        guard !visible.isEmpty else { return false }
        let current = (primaryHit?.id).flatMap { id in visible.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + offset, 0), visible.count - 1) } ?? 0
        let hit = visible[next]
        selectionIsDefault = false
        selection = [hit.id]
        cursor = hit.id
        if next == 0 {
            proxy.scrollTo(results.alternatives.isEmpty ? RowID.filters : RowID.alsoSearched)
        } else if let group = results.groups.first(where: { $0.hits.first?.id == hit.id }) {
            proxy.scrollTo(RowID.header(group.id))
        } else {
            proxy.scrollTo(RowID.hit(hit.id))
        }
        return true
    }

    /// The selection when results land: the student's, as far as it is still shown; else (or
    /// while it is the default) the first shown group's hits (at most 4, never mail), else the
    /// first hit.
    private func settleSelection(_ found: SearchResults) {
        let visible = visibleHits(found)
        let shown = Set(visible.map(\.id))
        if !selectionIsDefault {
            selection.formIntersection(shown)
            if !selection.isEmpty {
                if let cursor, !selection.contains(cursor) { self.cursor = visible.first { selection.contains($0.id) }?.id }
                return
            }
        }
        selectionIsDefault = true
        let firstGroup = found.groups.first { group in !found.collapses(group, expanded: expanded) }
        // Never mail or (md) documents: they are not the agent's sources.
        let leading = firstGroup?.hits.filter { $0.kind != .mail && $0.kind != .document }.prefix(Self.defaultSelectionLimit) ?? []
        let chosen = leading.isEmpty ? Array(visible.prefix(1)) : Array(leading)
        selection = Set(chosen.map(\.id))
        cursor = chosen.first?.id
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

    /// A web row opens its page in the browser; any other hit its place in the app.
    private func open(_ hit: SearchHit) {
        if hit.kind == .furtherReading, let url = hit.url {
            recordQuery()
            openURL(url)
            return
        }
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
            // Keyword hits show at once; a semantic list the index was too busy to give in time
            // is fused by a second search when it lands.
            var semanticWait: Duration? = Self.semanticWait
            while true {
                let found = try await engine.search(query, semanticWait: semanticWait)
                guard !Task.isCancelled else { return }
                if found.query.text != results?.query.text {
                    expanded = []
                    selectionIsDefault = true
                }
                results = found
                settleSelection(found)
                if opensFirstHit {
                    opensFirstHit = false
                    if let hit = visibleHits(found).first { open(hit) }
                }
                await openDecks(for: found)
                guard found.semanticPending, semanticWait != nil else { break }
                semanticWait = nil
            }
        } catch {
            Log.search.error("Search failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension SearchHit {
    /// The hit as one of the tutor's sources (M5); nil for mail and (md) documents (never a source:
    /// a kept document is personal, untrusted text the agent reads only with its own tools).
    public var chatSource: ChatSource? {
        let kind: ChatSource.Kind
        switch self.kind {
        case .transcript: kind = .transcript
        case .slide: kind = .slide
        case .note: kind = .note
        case .furtherReading: kind = .furtherReading
        default: return nil
        }
        let plain = text.isEmpty ? String(snippet.characters) : text
        return ChatSource(
            kind: kind, courseID: courseID, lectureID: lectureID, deckID: deckID, page: page, recordingID: recordingID,
            time: time, noteID: noteID, annotationID: annotationID, text: plain)
    }
}
