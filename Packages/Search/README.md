# Search

Search (PRD #20) over transcripts, slides, notes, verified further reading and mail, with results that jump to slide + time. M1: keyword search. M5: the Haiku query planner ("Also searched", DE↔EN), the on-device semantic index (NaturalLanguage), fusion, the Web group, multi-selection for the tutor. No automated test suite at present; verified by building and rendering (Search against mockup 07). The M1 golden queries and latencies below are history.

## M5 entry points

| Type | What |
|---|---|
| `SearchEngine(database:planner:semantic:)` | `search(_:)` never waits for the planner: it searches `query.text` + `query.alternatives` (keyword lists and the semantic list fused) and returns `SearchResults.alternatives` (what was also searched). `plannedAlternatives(for:)`: the cached plan, else the planner's answer (throws only `CancellationError`); the caller searches again with it. Tutor (builder B): `SearchEngine(database:, planner: nil, semantic: index).search(SearchQuery(text, scope: .material, courseID:, lectureID:, limit:))` |
| `HaikuQueryPlanner(client:database:)` | `QueryPlanning`: one Haiku 5.5 call per new plannable query, cached for good in `search_plan`. `HaikuQueryPlanner.version` (1) is in every cache key: bump it with the prompt |
| `QueryPlans` | `cached(_:in:)` (read with or without a planner: renders, iOS), `key(for:)`, `isPlannable(_:)` (a whole word of 3+ letters) |
| `actor SemanticIndex(services:)` | `SemanticSearching`. `start()` (follows `search_chunk`, reconciles in the background, returns at once), `stop()`, `warm()` (load the model ahead of a query), `reconcile()` (one batch, also for a live check), `nearest(to:query:limit:)` |
| `SearchQuery.Scope` | `.web` (further reading only: the Web segment), `.material` (the tutor), `.materialWithoutNotes` (audit 2026-10-19: a sub-agent task's search_lectures beside web tools), `.all` now includes further reading; `kinds` is public |
| `SearchHit` | `byline`, `url`, `annotationID` (a further-reading hit; `title` is its title), `text` (the chunk's whole text), `chatSource` (SearchUI: the hit as a `ChatSource`, nil for mail) |
| `SearchGroup.Kind.web` | "Web", after the notes, before mail |
| SearchUI `SearchResultsView(query:submits:context:)` | `context: Binding<ChatContext>` (default `.constant(.none)`): set to `.search(query:sources:)` with the selected hits (never mail) |
| SearchUI `SearchProviders` / `\.searchProviders` | the planner and the semantic index for the search screen; none by default |

## Surface

**`Search`** (StudyCore + GRDB, no SwiftUI)
- `actor SearchIndexer(services:debounce:)`: `start()` watches the library and catches up once (returns after the catch-up; keeps indexing until `stop()`), `reindexAll()`, `catchUp() -> Report`.
- `struct SearchEngine(database:planner:)`: `search(_ query: SearchQuery) async throws -> SearchResults`.
- `SearchQuery(_ text, scope: .all/.lectures/.notes, courseID:, alternatives:, limit: 100)`.
- `SearchResults`: `groups` (`SearchGroup`: `.lecture`, `.deck` or `.notes`, with course, lecture, deck, hits), `hits`, `count`, `courses`, `lectures`, `decks`, `duration`.
- `SearchHit`: kind, course/lecture/deck/page/recording/note, `time` (a line's start, a slide's first visit, a note's moment), `snippet: AttributedString` (matched words carry `SearchMatchAttribute`), `matchesAllTerms`, `target: SearchTarget` (`.lecture(id, page:, time:, plays:)`, `.course(id)`, `.mail(id)`, M6 `.note(id, course:)`).
- `protocol QueryPlanning`: the hook for "Also searched" phrasings (M5 Haiku planner, course-glossary DE↔EN). Alternatives are searched with the query and fused by rank.
- `Lemmatizer` (public since M2, frozen: `init()`, `language(of:fallback:)`, `lemmaText(of:language:)`): MailIntelligence writes `mail` chunks with the same `lemma_text`.

**`SearchUI`**
- `SearchResultsView(query:submits:)`: title "Search", subtitle "N results" (macOS). One surface that scrolls under the toolbar (no title bar line), at most 868 pt wide, leading (the M5 tutor inspector takes the rest): the All | Lectures | Notes filter (`FilterSegments`: content-sized segments on a grey track, the chosen one a neutral raised knob; ←/→ when focused; a segmented picker for VoiceOver) and the quiet "All courses ⌄" menu; then groups "● Data Centers  L2 · Virtualization & IaaS · Tue 13 Oct" over a hairline, notes under "Your notes". Rows: lecturer surname + `TimeChip` and the quoted line; "Slide 16" + `TimeChip` of the first visit, two-line snippet, 64 pt thumbnail card; notes "DC L2 · <title>" (its first heading; "DC L2 · Slide 15" untitled). Matches carry a rounded highlighter stroke (`MatchHighlightRenderer`). The selected hit sits on a neutral 10 pt block (`QuietFill`), never the accent. A group with only weak matches (not every word) collapses to its header with a chevron while another group matches fully; a click opens it. ↑/↓ select, ↩ or double-click opens, Space plays, context menu Open / Play. Empty query: nothing. No hits: the system's "No Results for “…”" title, no description. Results follow the index while the screen is open.
- `RecentSearches` (last 3 queries, newest first, distinct ignoring case; JSON array in `@AppStorage("recentSearches")`) and `RecentSearchesSection` (the sidebar's "Recent searches": a clock glyph in secondary grey per query; choosing one opens `StudyDestination.search(query)`). The search screen records the query on ↩ in the field and when a hit is opened or played.
- `SearchHit.destination` / `.playDestination` → `StudyDestination` (transcript → `.lecture(id, ReviewTarget(page:time:plays: true))`; slide → its first visit, else `.course`; note → its lecture at its page and moment).

## How it works

**Index** (`search_chunk` + the v4 FTS5 tables, written delete + insert):
- one chunk per transcript segment with the slide on screen at its midpoint (the timed span containing it), start/end, language, lecture and course. Only recordings filed to a lecture are indexed, so deleting a lecture removes its lines (its notes go by cascade);
- one chunk per deck page, with the footer and page number every page repeats removed (otherwise "Example" matches all 88 DC slides), on one line: each item after " · ", lines the slide wrapped joined back with a space (`SlideText.flatten`: a line continues the one before when it starts in lower case or with punctuation, or follows a comma, an open parenthesis or quotation, or a function word; a colon or a sentence end needs no " · ");
- one chunk per note, its blocks on one line with " · " between them, anchored like the note. M6: chips read as their labels ("S13", "37:59"), inline images, sketches and slide clips add nothing; a note without a lecture or course is indexed too (it opens in All Notes).

**M6 (notes):** a note on a slide still opens Review at its slide and moment (`.lecture`); any other note (a lecture's, a course's, one without a course) has `target = .note(id, course:)`, which SearchUI maps to `StudyDestination.notes(.course(id), note:)` (`.all` without a course). A note hit's top line is its title alone when the title already starts with "DC L2" (the Notes screen's names).
- Once per launch (`start()`), decks and notes whose chunks an earlier build cut differently (their text is not what the chunker gives now) are re-chunked, so a library indexed by an older build gets the current snippets without a schema change.
- `lemma_text` has one lower-cased NLTagger lemma per word of `text` (the word itself when there is none), so a lemma match can highlight the right word.
- Freshness: each unit (a recording's transcript, a deck, a note) stores its newest source `updated_at` in `source_updated_at`; a unit is re-chunked when that, its chunk count, or its lecture/course differs. The indexer observes `transcript_segment`, `deck_page`, `note`, `lecture_deck_span`, `lecture`, `deck` and `recording` and catches up after a quiet second (at most three).

**Query**
- Each word matches `text:"word"*` (prefix: results while typing) OR `lemma_text:"stem"*` for its German and English lemmas, lightly widened (`virtualized` → `virtualiz*`, which finds "virtualization"; `Prüfungen` → `prufung*`, which also finds "Prüfungszulassung"). Diacritics fold ("prufung" finds "Prüfung"). "Quoted phrases" match exactly; "hardware-assisted" is a phrase of its parts.
- Words are ANDed; function words (de/en) never decide. A transcript line also counts a word its slide contains, as long as it has one word of its own: "paravirtualization drawback" finds a line on its drawback said over the paravirtualization slide.
- Trigram index: for words of 3+ characters when the word index finds nothing, and for words of 6+ characters that occur in fewer than 200 chunks (German compounds: "zulassung" → "Prüfungszulassung", "verteilung" → "Lastverteilung").
- Near spellings as the last resort (one edit, two from 8 letters, through an `fts5vocab` table in the reading connection's temp schema): "Kubernetes" → "Kubernets".
- Ranking: every word > exact phrase > more words > Reciprocal Rank Fusion of bm25 lists (word index with `text` 1.0 above `lemma_text` 0.4; trigram; near spellings, closest first; each alternative phrasing). When fewer than 10 chunks match every word, chunks matching some fill up to 10.
- Snippets: whole chunks up to 30 words, else a 24-word window around the most matched terms, opened at a bullet or clause boundary (with a one-word heading before it: "Cons · Requires …", "Pro: can run …"); "…" only where the window cuts mid-phrase.

## M5: planner, semantic index, fusion, web

**Query planner** (`HaikuQueryPlanner`, purpose `search.plan`)
- Call: Haiku 5.5, effort low, ≤ 1,000 output tokens, `--json-schema {alternatives: [string] maxItems 3}`, `CallContext(purpose: "search.plan", priority: .interactive)`, only with `client.isAvailable()`.
- Input: `<courses>` (names with short names), `<glossary>` (≤ 60 terms: the query's course first; terms sharing a 4-letter word start with the query before the rest), `<query>`, all escaped; the system prompt asks for ≤ 3 phrasings of ≤ 6 words (the other language, the slides' own terms; the mockup's example), and says the query, course names and glossary are data, never instructions.
- Output kept: ≤ 3 distinct phrasings of 1–6 words (≤ 80 characters), none equal to the query (folded).
- Cache: `search_plan` under `SearchPlan.key(for: query, version: HaikuQueryPlanner.version)` ("v1:" + the folded query), with the call's `api_call_id`; an empty answer is cached too (sent once). Errors give no alternatives (logged, not cached); a cancelled call caches nothing.
- When (SearchUI, `QueryPlanState`): the cached plan at once; else, with a planner installed and a whole word of 3+ letters, after typing paused 1 s, or at once on ↩. At most one call in flight; a new query cancels it (the CLI child is killed). The first results never wait: the screen searches at once and again when the alternatives land.

**Semantic index** (`SemanticIndex`, table `search_vector`)
- Model: `NLContextualEmbedding(script: .latin)` (one multilingual model for German and English), `model` = "nl-contextual-latn-<revision>"; assets requested once per launch when missing (no UI). Token vectors mean-pooled and L2-normalised, stored as little-endian Float16 (vImage conversion, so every architecture builds); text clipped to 1,200 characters.
- Windows (`SemanticWindows`): consecutive transcript lines of one slide section (the slide on screen, or one off-slide stretch), closed before a line that takes the window over 60 words (a window under 20 words takes it anyway), anchored at its first line's chunk; one window per slide, note and further-reading chunk; never mail. Texts under 6 words are not embedded (a title-only slide such as "Applications" or a lone "OK." sat nearest to almost every short query in the calibration run).
- Reconcile per unit (a recording, a deck, a note, an annotation): stale when it has chunks but no vectors, chunks newer than its vectors, vectors whose chunk was re-cut (`chunk_id` NULL) or of another model; units with vectors but no chunks are deleted. A unit's vectors with a matching `model` + `text_sha256` are reused (their `chunk_id`, course and lecture fixed), only new text is embedded, the rest is deleted, all in one write that checks the unit's windows are still the ones embedded. Newest units first, serially, at background priority, `Task.yield()` between windows.
- When: `start()` reconciles once, then after `search_chunk` changes (quiet 5 s, at most three waits). A queued or running processing job (`job.state` queued/running) pauses the batch (retried after a minute). The model loads per batch and for queries and unloads after the batch, or 2 min after the last query (`warm()` loads it when Search opens).
- `nearest(to:query:limit:)`: the query and up to 3 alternatives embedded (the last 16 texts cached), the best cosine per vector over an in-memory Float32 matrix (`vDSP_mmul`; built on first use, dropped when vectors change; about 2 KB per 512-dimension vector), filtered by the query's scope kinds, course and lecture (a lecture's slides: the pages inside its deck spans). Kept: cosine ≥ 0.55 and within 0.12 of the best. Empty until the model and the index are there; never waits for a download.

**Fusion** (`SearchEngine`)
- The semantic index runs on its actor while the keyword lists are read (`async let`). The semantic list joins the RRF lists, so within a keyword tier a chunk it also found ranks higher; the tiers stay (every term > phrase > more terms > RRF). While the keywords found fewer than 10 hits, up to 3 chunks only the semantic list found follow them, each at cosine ≥ 0.80 and within 0.03 of the list's best (weak matches: their groups collapse while another group matches fully). The thresholds come from one calibration run on the parity library: mean-pooled `NLContextualEmbedding` vectors score 0.6–0.85 for unrelated text, so only the clear head of the list may fill in; below that the list only reorders keyword hits.
- `lectureID` filters every list: a chunk of the lecture, or a slide inside one of its deck spans (keyword and semantic alike).

**Further reading** (`further_reading` chunks, the Web group)
- The indexer writes one chunk per visible ai · `further_reading` annotation (`hidden_at` NULL, on a lecture): text "title · byline", its lecture (course), deck and page, `source_id` = the annotation, `source_updated_at` = its `updated_at`. It observes `annotation` (only the columns chunks are built from) and removes chunks whose annotation is hidden, gone or no longer the pass's.
- A hit's title, byline and URL come from the annotation; its target is the slide it was found for, and SearchUI opens the URL.
- Web group = the reading that matched (keywords or meaning) plus the reading the study pass verified for the slides of the other hits (a slide hit's page, a line's or note's slide), in hit order, at most 5: "your material first, then the web". It never collapses. `Scope.web` runs the material search and keeps the Web group.

**SearchUI**
- "Also searched" (`AlsoSearchedLine`): above the filters (10 pt), 8 pt in like the group headers, 12 pt: one `AIMark`, tertiary "Also searched", the alternatives that were searched in secondary joined by " · ". Hovering a term shows `xmark.circle.fill` (10 pt, tertiary); a click removes the term for this query and searches again. No line without a plan (or once every term is removed).
- Segments All | Lectures | Notes | Mail | Web.
- Web rows (`WebHitRow`): a secondary 13 pt glyph (`doc.text` for a paper: a DOI or arXiv link or "et al." in the byline; else `book`), the title 13 pt primary over "byline · domain" 11.5 pt secondary (domain without "www."), 7 pt vertical padding. A click selects the row and opens the page; ↩ too; no Space, no double-click.
- Selection: click selects one hit, ⌘-click toggles, ⇧-click selects the shown hits from the last clicked one, ↑/↓ move a single selection (from the last clicked). Consecutive selected hits share one `QuietFill` block (radius 10; corners only at the block's ends). ↩ / Space / double-click act on the last clicked selected hit. When results land and the student has not chosen, the default selection is the first shown group's hits (at most 4, never mail), else the first hit (mockup 07's four-hit block); the student's selection is kept as far as it is still shown.
- The binding gets `.search(query: <query>, sources: <the selected hits in screen order as ChatSource, mail left out>)` whenever the selection, the results or the query change.

## Budgets (M5)

Measured once, 2026-10-18, with a throwaway scratchpad tool (never committed) on a copy of `.data/parity/m5-sample/library` (two recorded lectures of about 40 and 70 minutes, 3 decks, 180 slide chunks), release build, run under `taskpolicy -b` (efficiency cores, as the index runs at background priority), an Apple silicon MacBook Pro. Model: `NLContextualEmbedding` Latin, revision 1, 512 dimensions, 256 tokens maximum.

| What | Budget | Measured |
|---|---|---|
| Keyword search (median of 5) | < 50 ms | 5–35 ms ("Xen" 5.6, "ELIZA" 7.6, "paravirtualization drawback" 17.4, "Nachteil Paravirtualisierung" + its 2 alternatives 33.8, "hardware support for virtual machines" 32.9) |
| Fused, warm (median of 5) | < 150 ms | 6–35 ms (the semantic list costs 0–3 ms once its query vectors are cached) |
| Fused, first query of a text | < 150 ms | 57–106 ms with the model loaded (one query embedding ≈ 80–90 ms on an efficiency core); 344 ms when the model also loads (≈ 210 ms): `warm()` loads it when Search appears |
| Planner on the first paint | never | never: `search(_:)` does not call it; SearchUI searches at once and again when the plan lands |
| Index a 90-minute lecture | < 15 s of one background core | **not met**: one embedding call takes 80–115 ms on an efficiency core whatever the window's length (20 single lines: 1.5–1.7 s), so DC L2's 198 transcript windows + about 85 slides take ≈ 30 s (the whole copy: 453 vectors in 43–52 s wall, 51–63 s CPU). A 90-minute lecture would take ≈ 35–40 s. The index runs serially at background priority, pauses for processing and never blocks the UI; the lever, if the integrator wants one, is fewer calls (windows of about 120 words halve the transcript's share) |
| Vectors resident | ≤ 30 MB per semester | 2 KB per vector: 453 vectors = 0.9 MB; a semester (≈ 42 lectures × 300) ≈ 25 MB |
| Process memory | the model only while it works | 54 MB before indexing → 58 MB after (the model unloads after the batch); 116 MB with the model loaded for queries (it unloads 2 min after the last one) |
| Second reconcile, nothing changed | | 8–11 ms (one aggregate query) |

Semantic quality (same run): mean-pooled contextual vectors are not trained for sentence similarity. Paraphrases with shared vocabulary find the right slides ("hardware support for virtual machines" → the hardware-assisted and VM slides at 0.89–0.90), but unrelated text still scores 0.6–0.85, title-only slides and filler lines sit near every short query, and German → English without a plan finds only the topic area. Hence: no texts under 6 words, the list mostly reorders keyword hits (RRF), and only its clear head fills in when the keywords find little. Centring the vectors on their mean did not help (tried once, not kept).

## Golden queries (DC L2 and CL L1)

| Query | Top results |
|---|---|
| paravirtualization drawback | DC L2's line at 37:59 on the drawback of paravirtualization (slide 16, the paravirtualization slide), then a second line on it at 39:08, then slides 16, 15, 21, 18, 33, 17 |
| ELIZA | CL L1 slides 11–13 and 15, and the line at 7:25 that introduces ELIZA |
| Xen | DC L2's Xen slides, then the transcript lines that name it |

## Latencies

Debug build, Apple silicon MacBook Pro, 2026-10-17 (budgets: query < 50 ms, 90-minute transcript < 1 s).

Golden queries on two recorded lectures (DC L2 and CL L1 transcripts, both decks, one note), median of 7:

| Query | ms | Hits |
|---|---|---|
| paravirtualization drawback | 5.4 | 9 |
| ELIZA | 2.7 | 7 |
| paravirt | 3.4 | 7 |
| virtual machine | 12.3 | 79 |

Semester-sized synthetic library (3 courses × 14 lectures × 900 lines + 50 slides each: 39 900 chunks; every common word in about a fifth of the chunks, so harsher than real lectures), best of 7:

| Query | ms |
|---|---|
| hypervisor memory | 23.8 |
| virtual machine migration | 34.9 |
| Prüfung | 14.8 |
| zulassung / verteilung (trigram) | 15.6 / 21.0 |
| hypervisr (near spelling) | 19.4 |
| the | 14.8 |
| "guest operating system" | 2.9 |

Indexing a 90-minute transcript (1 080 lines, 15 120 words, NLTagger lemmas): 200 ms.

## Wiring (for the integrator)

- `AppModel` owns one `SearchIndexer(services:)`; `startBackgroundWork` calls `await searchIndexer.start()` (catch-up of an existing library happens there; a first run over a semester takes a few seconds and never blocks the UI).
- The Search sidebar item shows `SearchResultsView(query:)` fed by the toolbar search field (`RootView`'s `.searchable`); the view sets its own title and subtitle. Moving focus from the search field to the results on ↓ or Return (`onSubmit(of: .search)`) is the app's call.
- `\.openDestination` and `\.studyServices` must be installed (thumbnails open the deck PDF from the blob store, bitmaps cached in `paths.caches/Slides`, the same folder live capture uses).
- Sidebar (mockup 07): `RecentSearchesSection()` inside the sidebar `List`, after the Courses section, only while `selection == .search` (mockup 01 Today has none). It renders nothing while there are no recent searches and routes a click through `openDestination(.search(query))`.

## Mail (M2)

`SearchQuery.Scope.mail` (the "Mail" segment) searches the `mail` chunks MailIntelligence writes; `.all` lists mail after lectures and notes. One hit per message (its best chunk), `title` = subject, `sender`, `mailMessageID`, `target = .mail(id)` → `StudyDestination.mail(id)`. A group of only weak mail matches collapses to its best subject (mockup 07). `SearchIndexer.reindexAll()` deletes mail chunks too (the app never calls it; the next mail pipeline pass would write them again); orphan removal leaves them alone.

## Requests for the integrator

Handled in the M1 integration: `AppModel` owns the indexer and starts it at launch; the Search item shows `SearchResultsView` fed by the toolbar field (⌘F focuses it); requests 1–2 stay as they are (no v5). The list as written:

1. `SearchChunk` / `SearchChunk.Draft` have no public initializer outside StudyCore (the macro's memberwise init is internal) and `Draft` is not `Sendable`, so `SearchChunk.insert { Draft(…) }` cannot be written from this package. The indexer inserts with plain SQL (`ChunkRow.insert`, still delete + insert, never INSERT OR REPLACE). A public memberwise init on `SearchChunk.Draft` (v5 or a StudyCore patch) would let it use the typed insert; nothing else depends on it.
2. `Search` depends on `GRDB` directly (`https://github.com/groue/GRDB.swift`, from 7.6.0, resolved to the 7.11.1 SQLiteData already uses) for `DatabaseRegionObservation`, raw FTS5 SQL and `fts5vocab`. No `project.yml` change is needed: the app links the `Search`/`SearchUI` products and SwiftPM resolves the same GRDB.
3. Branch: this work is on `m1/search` (the plan says `m1/d-search`).

## M5 requests for the integrator

1. **`AppModel` (Mac only)**: one `SemanticIndex(services:)`; `await index.start()` in `startBackgroundWork` after `searchIndexer.start()` (it returns at once and reconciles in the background), `await index.stop()` at quit. Nil on iOS and in snapshot and parity modes (renders then show keyword hits and the cached plan, as mockup 07 needs).
2. **Planner (Mac only)**: one `HaikuQueryPlanner(client: <the app's ClaudeClient.socrates>, database: services.database)`; nil without a client and on iOS.
3. **Environment**: `.environment(\.searchProviders, SearchProviders(planner: planner, semantic: index))` on the main window's content (RootView), so `SearchResultsView` sees both. Nothing installed means keyword search plus cached plans.
4. **The tutor binding** (plan §7.3): `DetailView` passes `SearchResultsView(query: query, submits: searchSubmits, context: $chatContext)` and attaches `.chatInspector(isPresented: showsChat, context: chatContext)` with the tutor toolbar style. The view writes `.search(query:sources:)` as soon as it appears and whenever the selection, the results or the query change (mail hits never become sources).
5. **One index for the tutor**: B's `TutorChat.spec(services:search:)` should get `SearchEngine(database: services.database, planner: nil, semantic: index)` with the same `SemanticIndex` instance (one model, one matrix).
6. **Packages**: `Search` now depends on `ClaudeKit` (already linked by the app); no `project.yml` change.
7. **Index budget** (plan §6, "a 90-minute lecture < 15 s of one background core"): not met on the efficiency cores (≈ 35–40 s; see Budgets). Nothing blocks on it (background, serial, resumable, never re-embeds unchanged text); the plan's budget or the window size (§5.1.4, about 60 words) is a product decision.
8. **Live check** (plan §7.5): one planner call for "Nachteil Paravirtualisierung" (note the alternatives, the `search_plan` row and the `api_call` row, purpose `search.plan`); the semantic index of `.data/m5-live/library` (time and resident memory, the log line "Semantic index: N units, M windows embedded …"); and `ClaudeKit`'s web tool loop through the tutor (the init line lists `mcp__studyportal__*`, `WebSearch`, `WebFetch` and only `studyportal` as server; one extra ledger row for the web tools).

## M5 design notes for the integrator

**DESIGN 8.1 Search** (replace the closing "Later: …" sentence):
"M5: an "Also searched" line above the filters when the planner's alternatives were searched: one sparkle, tertiary "Also searched", the alternatives in secondary joined by " · " (12 pt, 8 pt in like the group headers, 10 pt above the filters); hovering a term shows a small × that removes it and searches again; no line without a plan. `FilterSegments` All | Lectures | Notes | Mail | Web. A Web group after Your notes and before Mail: `globe` + "Web" header; rows of a secondary glyph (`doc.text` a paper, `book` a manual or book), the title 13 pt primary over "byline · domain" 11.5 pt secondary; a click opens the page in the browser; it holds the reading that matched and the verified reading for the slides of the other hits (≤ 5) and never collapses. Multi-selection: click selects one, ⌘-click toggles, ⇧-click extends, ↑/↓ move one; consecutive selected hits share one `QuietFill` block (radius 10). Until the student chooses, the first group's hits (≤ 4) are selected (mockup 07). Results show at once (keyword and on-device meaning); the alternatives fuse in when the plan lands; nothing waits for Claude."

**DESIGN 6.3 Toolbar**, Search row: Trailing "[search field] [`bubble.left` Tutor toggle]" (builder B's tutor style); the "Also searched" line belongs to the content, never the toolbar.

**DESIGN §9 strings** to add: "Also searched" (Search, before the alternatives), "Web" (segment and group header), "Remove" (the help and accessibility action of an alternative's ×).

**decisions.md rows**:
| Decision | Why |
|---|---|
| Query planner: Haiku 5.5, effort low, ≤ 1,000 tokens, `--json-schema`, ≤ 3 phrasings of ≤ 6 words; asked only for a settled query (typing paused 1 s, or ↩) with a whole word of 3+ letters, one call in flight, cancelled when the query changes; answers (empty ones too) cached for good in `search_plan` under "v<version>:" + the folded query | search costs no usage per keystroke; a repeat or a recent search costs nothing; the first results never wait for Claude |
| Semantic model: `NLContextualEmbedding` Latin script (one multilingual on-device model), mean-pooled token vectors, L2-normalised, Float16 in `search_vector`; model loaded per batch and for queries, unloaded after the batch and 2 min after the last query | no network, no usage, German and English in one space; memory only while it works |
| Semantic windows: transcript lines of one slide section up to about 60 words (anchored at the first line), one per slide, note and further-reading chunk; never mail; reconciled per unit by text hash | one vector per thought, not per line; a re-cut embeds only changed text; mail stays out of anything web-adjacent |
| Fusion: the semantic list is one more RRF list; keyword tiers stay (every term > phrase > more terms > RRF); while fewer than 10 keyword hits, up to 3 semantic-only hits follow them (cosine ≥ 0.80, within 0.03 of the best); keywords and meaning run concurrently; texts under 6 words are not embedded | exact words stay on top; meaning fills in what the words miss (German query, English slides) without burying keyword hits |
| Web group: the reading that matched plus the study pass's verified reading on the slides of the other hits (≤ 5), never collapsed | mockup 07: "Your material first, then the web"; a reading's title rarely shares the query's words |
| Default selection: the first shown group's hits (≤ 4, never mail), else the first hit | mockup 07's four-hit block; the tutor starts from the best hits before the student picks |
| Source check (StudyPass `WebCheck`): public https hosts only; refuse localhost/.localhost/.local/.internal, single-label names, loopback, private (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7), link-local (169.254/16, fe80::/10), unspecified, multicast and reserved addresses, as literals or as any resolved address (getaddrinfo off the actor); every redirect hop checked the same way | the check fetches URLs a prompt-injected page could have planted, from the student's Mac (SSRF) |
| Study pass: a research run at its turn limit is done without sources (`research.turn_limit`), no attempt, never retried | asking again would end the same way and spend usage |
| Study pass: settled fingerprints kept in `AppPaths.caches/StudyPass/settled.json` (with `promptVersion`; held-stage and run-cap lectures not written) | no launch burst: the first pass after launch loads only lectures whose cheap fingerprint changed |
| Claude Code tool loops with web tools: `--tools` and `--allowedTools` name only the built-ins asked for after `mcp__studyportal`; the init check wants exactly the app's tools plus those built-ins and no other connected server; one ledger row per run for the web tools' unstreamed cost (`modelUsage`) | the tutor's web research runs isolated like the one-shot research runs, and its cost is logged |

## Shared decks (mr, workstream B)

One deck may serve several lectures, each with a page range (`LectureSlides`). Slide chunks stay per
deck page (indexed once, whatever lectures show them; transcript chunks keep the slide on screen from
their recording's timed spans).
- **A slide hit** goes to the lecture whose range covers the page (`SearchEngine.firstVisit`): a
  timed visit counts only inside its lecture's range of the deck, the earliest lecture first; a
  lecture-scoped search prefers its own lecture when its range covers the page.
- **A lecture-scoped search** (keyword and semantic) keeps the lecture's own chunks and only the slide
  chunks of its current range (`LectureSlideScope`: deck + `first_page`…`last_page`); a lecture
  without a range keeps the pages its timed spans visited, as before.
