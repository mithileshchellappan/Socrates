import StudyCore

/// Apple Notes-style notes (PRD #15, #16; docs/plan-m6.md): the logic under the Notes screen and
/// the rich editor. Storage is `note.blocks` (`NoteBlock`, StudyCore); images and sketches live in
/// the BlobStore (§4 of the plan). Filled by M6 workstream A.
public enum NotesModule {
    public static let moduleName = "Notes"
}
