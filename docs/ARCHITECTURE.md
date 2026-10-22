# Architecture rules

How Socrates' Swift code is put together. Every change follows these rules. A review that finds a
break of one is a finding of its own, even when the code works.

## Layers and dependencies
- **The app target is the composition root.** It creates the database, the services and the models,
  and wires them to views. It holds no feature logic.
- **A feature is a package with a core and a UI.** The core holds models, repositories and services,
  with no SwiftUI, AppKit or UIKit. The UI holds the views, which depend on the core and never the
  other way round. Only packages named as platform UI (`Panes`, the app's `macOS/` and `iOS/`
  folders) import AppKit or UIKit.
- **Dependencies point one way, with no cycles.** A package uses another package's public API only.
  Shared vocabulary lives in `StudyCore` (data) or `StudyUI` (design system), never copied.
- **Public API is deliberate.** `public` only for what another package uses. Everything else stays
  `internal` or `private`.

## State
- **One source of truth per fact.** Persistent facts live in the database and views observe them
  (SQLiteData `@FetchAll` / `@FetchOne`, or a repository's async sequence). A cached copy of a row
  needs a reason and an invalidation path.
- **Derived values are computed, not stored.** If two values can disagree, one of them should not
  exist.
- **UI state lives in `@Observable` models on the main actor,** owned by the view or screen that
  needs them and passed down. Views render state and send intents. They do no I/O, parsing or
  business logic.
- **States are explicit types.** Use enums with associated values for phases (`recording`, `paused`,
  `stopped`) so invalid combinations cannot be written. Do not use bags of booleans.

## Concurrency (Swift 6, strict)
- UI, view models and AppKit/UIKit code are `@MainActor`. Shared mutable resources (the recorder, a
  link, a transcription engine) are actors. Data crossing isolation is a `Sendable` value type.
- Use structured concurrency. Every `Task` has an owner that keeps it and cancels it (a model's
  lifetime, `.task` on a view, a task group), so there is no fire-and-forget. Long work checks
  cancellation.
- Banned: `DispatchQueue` in new code, locks where an actor fits, `@unchecked Sendable`,
  `nonisolated(unsafe)`.

## Types and boundaries
- Value types (`struct`, `enum`) for data, commands, events and messages; classes only for identity
  and lifetime (models, controllers, actors).
- Identifiers are typed (`Lecture.ID`, not `String`).
- **Anything that crosses a process or a device carries an id and is applied once.** That covers App
  Intents, the Live Activity, iCloud sync and the phone–Mac link. It is also validated against the
  current state on arrival.
- Codable contracts that leave the process are versioned and stay readable by older and newer
  builds.
- Errors are typed at module boundaries and handled where they can be acted on. Never swallow an
  error silently: log it with `os.Logger` (one category per module) and surface it per the PRD's
  trust rules.

## Dependencies and abstraction
- Inject dependencies through initializers or the SwiftUI environment (swift-dependencies'
  `@Dependency` where the package already uses it).
- No new singletons or global mutable state. Existing `shared` instances are not a pattern to copy.
- A protocol needs two real implementations or a real boundary (a transport, an engine, the model
  provider). Do not abstract speculatively, and do not add layers that only forward calls.

## Views
- Keep views small and composed. Extract a subview when a `body` mixes concerns, not to hit a line
  count.
- `body` does no work: no sorting, filtering, formatting of large data or I/O. Prepare it in the
  model.
- No `GeometryReader` for size observation (use `onGeometryChange`). Use native components, and
  follow the PRD's UI rules and `docs/DESIGN.md`.

## Code
- One primary type per file. The file and the type say what it is. No `Manager`, `Helper` or
  `Utils` grab bags.
- Delete dead code; do not comment it out. Comments say why, not what.
- Repetition is fine until the third copy. Then extract, in the package that owns the concept.
- Hand-written code over clever generic machinery. Read the surrounding code and write like it.

## Skills for agents
Agents load the installed Swift skills when they apply:
- `swiftui-pro` for views;
- `swift-concurrency-pro` for isolation, tasks, streams and cancellation;
- `swiftui-performance-audit` for invalidation, identity and work in `body`;
- `improve-codebase-architecture` for structure.

The rules in this file and CLAUDE.md win over any skill's advice.
