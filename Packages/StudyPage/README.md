# StudyPage

Claude's study text drawn natively, and the student's own notes beside it.

| Product | Contents |
|---|---|
| `StudyPageFormat` | No UI: the Markdown block parser (shared with the agent panel's answers), inline math, `ChartSpec`, the Mermaid subset with its layout, `CodeLexer`, text-quote anchors for the student's marks. |
| `StudyPageUI` | Platform UI (Mac): the block views, `LectureNotesView` (one read-only TextKit 2 document with select-and-ask, kept answers and highlights), `NotesPageLayout`, `YourNotesColumn`, `LectureNotesCommand` and the Lecture menu's focused values. |

No automated test suite; verified by building and rendering (`tools/parity`).

## Panes (the side panes milestone)

The notes page and Review show the student's notes in a side pane (docs/DESIGN.md 6.4, 8.9). A
pane is drawn in its own hosting view, so what it shows comes through `@Observable` state, never
through the screen's values, bindings or environment.

- **`YourNotesColumn`** has no header of its own (the pane's 36 pt header says "Your notes"), no
  `isShown`, `hide` or width readers. Its inputs are closures read in its body, so Observation
  follows them across hosting views:

  ```swift
  YourNotesColumn(
      lectureID: id,
      sections: { state.sections },                 // the notes page; Review passes none
      follow: { .section(state.readingSection) },   // or .page(model.session.shownPage) in Review
      recordingID: model.recording?.id,             // Review only: a new note's recording
      playhead: { model.player?.time },             // Review only: a new note's moment
      onOpenSlide: { page in … },                   // nil: a chip opens Review at the slide
      onLink: { ReviewNoteLinks.open($0, model: model) }, // Review: a chip in a note moves it
      onEditingChange: { state.typingInColumn = $0 }
  )
  ```

  With a recording, a note started in the column gets it and the playhead then (as Review's This
  slide); the lecture's own note shows its moment after its last word (a slide's group has its
  chip instead). Without a deck such a note lists by its moment once the typing ends (it stays in
  the lecture's own note while it is typed in).

  `YourNotesFollow.page(n)` gives slide n's group the quiet fill and scrolls it a third down, as
  `.section` does for a section's groups: never while the pointer is over the column, while one of
  its notes is typed in, or within 2 s of the student scrolling it. The ink thumbnails keep their
  width while a divider is dragged (`defersReflowWhileResizing()`).
- **`LectureNotesView`** takes `commands: LectureNotesCommandRelay?`. Given a relay (Review's
  Summary tab, which sits in a pane), the view publishes no focused values itself; the screen
  publishes the relay's `ask` and `highlight` from its own tree, where the menu reads them. This
  is the plan's `publishesCommands` flag and its hand-over in one parameter, like `onChatPassage`.
- **Live resize.** While `\.isLiveResizing` is on, the document's code, tables, diagrams, charts
  and slides keep their width (each attachment's hosting view reads the flag through the
  coordinator's `NotesLiveResize` box) and the prose is indented again at most every 100 ms, once
  more when the drag ends.
