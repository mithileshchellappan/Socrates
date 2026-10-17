import StudyCore

/// Keyword search (PRD #20, M1 part): `SearchIndexer` chunks transcripts, slides and notes into
/// `search_chunk` (with NLTagger lemmas) and keeps it current; `SearchEngine` queries the FTS5
/// tables. See Packages/Search/README.md.
public enum SearchModule {
    public static let moduleName = "Search"
}
