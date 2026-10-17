import StudyCore

/// Keyword search (PRD #20, M1 part): chunks transcripts, slides and notes into `search_chunk`
/// (with NLTagger lemmas) and queries the FTS5 tables. Workstream D fills this in; see
/// docs/plan-m1.md.
public enum SearchModule {
    public static let moduleName = "Search"
}
