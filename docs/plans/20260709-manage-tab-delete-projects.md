# Manage tab: delete Claude project data or the whole project — work plan

Issue: [#7 add possibility to delete claude projects files and delete projects](https://github.com/HawkeyePierce89/CCSync/issues/7)

## Overview

Add a third "Manage" tab that lets the user select projects and permanently delete either
their Claude Code footprint ("Delete Claude data") or that footprint plus the project
folder on disk ("Delete project entirely"). No snapshot is taken. All semantics live in
Core: a new `FileSystem.removeItem` primitive, a `ManagePlan` with per-project folder
status, a Manage-specific `SelectionTree` builder, and a `DeleteService`/`DeleteReport`
shared verbatim by a new `ccsync delete` CLI command (dry-run by default) and the GUI
(irreversibility modal required). Backup and Restore behaviour is untouched; the existing
149 tests stay green.

## Context

- Files involved (Core): `Sources/CCSyncCore/FileSystem.swift`, `SelectionTree.swift`,
  `BackupPlan.swift`, `ProjectInventory.swift`, `BackupCollector.swift` (session-artifact
  discovery to extract and share), `JSONMerge.swift` (key-removal discipline),
  `KnownPaths.swift` (`normalize`, path helpers), `CLI.swift`, `Model/JSONValue.swift`.
- New Core files: `Sources/CCSyncCore/ManagePlan.swift`,
  `Sources/CCSyncCore/DeleteReport.swift`, `Sources/CCSyncCore/ProjectDataLocator.swift`,
  `Sources/CCSyncCore/DeleteService.swift`.
- Files involved (App): `App/CCSync/CCSyncApp.swift` (RootView picker), plus new
  `App/CCSync/ManageView.swift`; reuses `ProjectSelectionTreeView.swift`.
- Files involved (CLI wire-up): `Sources/ccsync/main.swift` (no logic change needed;
  `delete` uses the `RealFileSystem` already injected).
- Tests: `Tests/CCSyncCoreTests/Support/InMemoryFileSystem.swift` (add `removeItem`
  journaling + a fault hook), new test files under `Tests/CCSyncCoreTests/`.
- Docs: `README.md`, `CLAUDE.md`.
- Related patterns to follow: `RestoreService`/`RestoreReport` (service +
  machine-readable report, throw only on stop conditions, skip+warn otherwise),
  `CLI.runRestore` + `ArgParser` + `reportJSON`, `BackupViewModel`/`RestoreViewModel`
  (`loadPlanIfNeeded`, off-main-thread `Task.detached`, dumb view), `DisclaimerSheet`
  (modal), `SelectionTree(plan: BackupPlan)` builder,
  `BackupCollector.collectSessions`/`listTodos` (artifact discovery), the "don't scan the
  disk" journal-assertion discipline.

## Locked decisions

- **Best-effort deletion.** For "Delete project entirely", the Claude-data cleanup
  (history dir + linked artifacts + one `~/.claude.json` key) always proceeds; only the
  project-folder removal is refused-and-warned when the folder path fails a sanity guard.
  A folder that is simply already gone is treated as done (data still cleaned). An orphan
  (empty path) under "entirely" degenerates to data-only with no error and no warning.
  `skippedProjects` is reserved for projects where **nothing** was deleted at all. Never
  report a folder as deleted when it wasn't.
- **Folder-removal sanity guards** (checked by `DeleteService` at execution time, and
  pre-computed by `ManagePlan` for the pre-run UI signal):
  - *unsafe path* — the path is `/` or equals the home directory (compare normalized);
  - *missing* — no directory exists at the path;
  - *symlink* — a symlink at the project path never qualifies as a deletable folder: the
    folder removal is refused with its own warning and the target is never touched. Only
    a real (non-symlink) existing directory is ever removed.
- **Pre-run visibility (`folderDeletable`).** `ManagePlan` computes, in Core, a
  per-project folder status (`deletable` / `unsafePath` / `missing` / `symlink` /
  `orphan`) with a caption for the row, and a `deletionSplit(selection:)` helper for the
  confirmation modal's "N project folders will be deleted, M will have Claude data
  cleaned only" counts. This is an early signal only: `DeleteService` re-checks the same
  guards at execution time (the CLI has no UI, and the disk may change while the window
  is open).
- **Cause-specific warning wordings** (verbatim — tests and users tell the cases apart by
  them):
  - missing: `project folder not found on disk — Claude data removed, nothing to delete
    for the folder`
  - unsafe: `refused to delete project folder (unsafe path: <path>) — Claude data removed`
  - symlink: `project path is a symlink — folder not removed, Claude data removed`
  - already-empty project: skipped with reason `nothing to delete — already gone`
- **No snapshot, no undo.** The snapshot policy stays restore-only. The GUI modal states
  the deletion is permanent and irreversible; the CLI is dry-run unless `--yes` is given.
- **Shared artifact discovery.** The per-session artifact discovery (history `.jsonl`
  stems → `file-history/<uuid>/`, `session-env/<uuid>/`, `todos/...`) is extracted from
  `BackupCollector` into one shared internal helper used by both the collector and
  `ProjectDataLocator` — plus an equivalence test pinning that both see the same paths on
  the same fixture home, so the two callers cannot drift.
- **`~/.claude.json` reads in `DeleteService` apply the same symlink guard as
  `BackupPlan`** (a symlinked config is rejected, never followed).

## Development Approach

- Testing approach: TDD for all Core work (write journal-asserting tests first, then
  implement); the App layer carries no logic and is verified by the `xcodebuild` build
  gate — all testable semantics live in Core.
- Complete each task fully (implementation + tests + green suite) before the next.
- Preserve every core invariant: only `KnownPaths`/explicit project paths are touched;
  `listDirectory(home)` is never called; `~/.claude.json` stays generic `JSONValue` with
  a surgical one-key removal; selection logic stays in Core; disk I/O only through
  `FileSystem`.
- CRITICAL: every task includes new/updated tests, and the full suite must pass before
  starting the next task.

## Implementation Steps

### Task 1: FileSystem delete primitive + journaling

Files:

- Modify: `Sources/CCSyncCore/FileSystem.swift`
- Modify: `Tests/CCSyncCoreTests/Support/InMemoryFileSystem.swift`
- Create: `Tests/CCSyncCoreTests/FileSystemRemoveItemTests.swift`

- [x] Add `func removeItem(_ path: String) throws` to the `FileSystem` protocol
      (recursive: removes a file, or a directory and its entire subtree). Document that,
      like `FileManager.removeItem`, a symlink target is not followed — only the link
      entry is removed — and that removing a missing path throws
      `FileSystemError.notFound(path)`.
- [x] Implement in `RealFileSystem` wrapping `FileManager.removeItem(atPath:)`, throwing
      `FileSystemError.notFound` when the path does not exist (so callers can treat
      missing as skip+warn rather than a hard crash).
- [x] Implement in `InMemoryFileSystem`: add `.removeItem(String)` to the `Access` enum
      (+ its `path`), journal it, remove the exact file and every file/directory whose
      path is `path` or has prefix `path + "/"`; throw `notFound` when nothing matches.
      Add an injectable fault hook (e.g. `var removeItemErrors: [String: Error]`) so a
      test can force a permission-style failure at a specific path.
- [x] Write tests: file removal, recursive directory removal (journal shows a single
      `.removeItem` for the root and the subtree is gone), removing a missing path
      throws, the fault hook throws, and unrelated paths are untouched.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: ManagePlan (folder status) + Manage selection-tree builder

Files:

- Create: `Sources/CCSyncCore/ManagePlan.swift`
- Modify: `Sources/CCSyncCore/SelectionTree.swift`
- Create: `Tests/CCSyncCoreTests/ManagePlanTests.swift`
- Create: `Tests/CCSyncCoreTests/ManageSelectionTreeTests.swift`

- [x] Add `ManagePlan(fileSystem:paths:)`: wraps a `BackupPlan` and computes, per
      project, a `FolderStatus` (`deletable` / `unsafePath` / `missing` / `symlink` /
      `orphan`) keyed by `encodedName`. Status derivation: orphan when `path.isEmpty`;
      `unsafePath` when the path is `/` or normalizes to the home directory; `symlink`
      when the entry at the path is a symlink; `missing` when no directory exists there;
      else `deletable`. Existence checks go through `FileSystem` on the explicit project
      paths only (invariant #1 — no scanning).
- [x] Add `ManagePlan.folderCaption(for encodedName:) -> String?` — the single Core
      wording for the row caption (`nil` for `deletable`; e.g. "folder already gone —
      Claude data only" for `missing`, "unsafe path — Claude data only" for `unsafePath`,
      "symlink — Claude data only" for `symlink`; orphans keep their existing
      `incompleteSummary`, no extra caption).
- [x] Add `ManagePlan.deletionSplit(selection:) -> (folders: Int, dataOnly: Int)` for the
      modal counts (selected projects whose folder will be removed vs. data-only).
- [x] Add `SelectionTree(managePlan:)`: `globalSelected = false` (nothing global is
      deletable), `projectsMasterSelected = true` (leaves are live/enabled), every
      project node `isSelected = false` and `isSelectable = true` — including orphans
      (`path.isEmpty`). This is the inverse of `init(plan: BackupPlan)`, which leaves
      projects on and orphans non-selectable.
- [x] Confirm `resolvedSelection()`, `setProject`, `folderState`, and `setFolder` need no
      change: with every node selectable and default-off, a fresh Manage tree resolves to
      an empty `projectEncodedNames`, and folder tri-state derives `.off`.
- [x] Write tests: folder-status derivation for all five cases (fixture home with a
      normal project, a missing folder, a symlinked path, a `/`/home path, an orphan);
      caption wording per status; `deletionSplit` counts for a mixed selection; default
      Manage tree has nothing selected (`resolvedSelection().projectEncodedNames.isEmpty`);
      orphans are selectable and can be toggled on; `setProject`/`setFolder` flip nodes
      on; `folderState` reports `.off`/`.mixed`/`.on` as leaves are toggled;
      `ProjectPathTree(nodes:)` over a Manage tree keeps orphans in `orphans` and marks
      all leaves `isSelectable`; the journal shows no `listDirectory(home)` and only
      explicit project paths probed.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: Shared artifact discovery, DeleteReport, locator, and ~/.claude.json key removal

Files:

- Modify: `Sources/CCSyncCore/BackupCollector.swift` (extract the shared discovery
  helper)
- Create: `Sources/CCSyncCore/DeleteReport.swift`
- Create: `Sources/CCSyncCore/ProjectDataLocator.swift`
- Modify: `Sources/CCSyncCore/JSONMerge.swift` (or a small dedicated helper) for surgical
  key removal
- Create: `Tests/CCSyncCoreTests/ProjectDataLocatorTests.swift`

- [ ] Extract the per-session artifact discovery out of `BackupCollector` into one shared
      internal helper (list `projects/<encoded>/` for non-dir, non-symlink `.jsonl`
      stems; map each stem to `file-history/<stem>/`, `session-env/<stem>/`, and matching
      `todos/` entries; only listable, non-symlink roots are entered — same no-follow
      discipline). `BackupCollector` and `ProjectDataLocator` both call it — one
      implementation, no drift.
- [ ] Define `DeleteOperation` enum: `.claudeDataOnly`, `.entireProject`.
- [ ] Define `DeleteReport` (Equatable, Sendable): `dryRun: Bool`;
      `deletedProjects: [DeletedProject]` where `DeletedProject` = `path`, `encodedName`,
      `folderRemoved: Bool`, `removedPaths: [String]` (the exact paths targeted);
      `skippedProjects: [SkippedProject]` = `path`, `encodedName`, `reason`;
      `warnings: [String]`. Mirror `RestoreReport`'s shape/naming so the CLI JSON
      serialisation is symmetric.
- [ ] Add `ProjectDataLocator` (Core): given `fileSystem`, `paths`, and an encoded
      project name, return the ordered set of removable Claude-data paths — the
      `projects/<encoded>/` directory plus the linked per-session artifact paths from the
      shared helper. It reads no file contents and never lists `home`.
- [ ] Add a surgical `~/.claude.json` key remover (same discipline as `JSONMerge`:
      generic `JSONValue` in, remove exactly `projects[<path>]`, every other
      key/project/unknown-future key preserved) returning the new document and whether
      the key existed.
- [ ] Write tests: the locator finds the history dir + only the artifact subdirs/files
      belonging to the project's sessions (never another project's), skips symlinked
      roots, and lists only `KnownPaths`; an **equivalence test** — on one fixture home,
      the locator's path set matches exactly what `BackupCollector` collects for the same
      project; the key remover removes exactly one project entry, is a no-op (unchanged
      doc, `existed == false`) when the path/`projects` object is absent, and leaves
      sibling projects and unknown top-level keys intact.
- [ ] Run `swift test` — must pass before Task 4.

### Task 4: DeleteService orchestration

Files:

- Create: `Sources/CCSyncCore/DeleteService.swift`
- Create: `Tests/CCSyncCoreTests/DeleteServiceTests.swift`

- [ ] `DeleteService(fileSystem:paths:)` with `@discardableResult func delete(selection:
      Selection, operation: DeleteOperation, dryRun: Bool) throws -> DeleteReport`.
      Internally build `ProjectInventory.list(...)` from a fresh `~/.claude.json` read
      with the **same symlink guard as `BackupPlan`** (a symlinked config is rejected);
      act on each inventory entry whose `encodedName ∈ selection.projectEncodedNames`.
- [ ] Per selected project (best-effort):
  - Delete Claude data: gather locator paths + remove the `~/.claude.json`
    `projects[<path>]` key. Remove each existing path via `removeItem`; a path already
    missing is a warning, not a failure. Record a `DeletedProject` with `removedPaths`
    and `folderRemoved: false`. If nothing was present to remove (no history dir, no
    artifacts, no matching key), record it under `skippedProjects` with reason
    `nothing to delete — already gone`.
  - Delete project entirely: do the Claude-data cleanup above, then attempt the
    project-folder removal, applying the guards (skip-folder + per-project warning,
    never a crash) with the **locked verbatim wordings**: unsafe path (`/`/home) →
    `refused to delete project folder (unsafe path: <path>) — Claude data removed`;
    symlink at the path → `project path is a symlink — folder not removed, Claude data
    removed` (the target is never touched); folder already gone → `project folder not
    found on disk — Claude data removed, nothing to delete for the folder`. For an
    orphan (`path.isEmpty`), degenerate to data-only silently (no warning, no error).
    Set `folderRemoved` accordingly — never `true` unless the folder was actually
    removed.
- [ ] `dryRun`: compute the identical report but perform no `removeItem`/`writeData` — so
      the would-be report equals the real report for the same selection (acceptance #5
      parity). Only side effects differ.
- [ ] Write-back of the mutated `~/.claude.json` happens once at the end (only when a key
      was actually removed and not dry-run), reusing the same-document discipline as
      `RestoreService`.
- [ ] Error handling: a `removeItem`/`writeData` failure (e.g. permission) is a stop
      condition — throw a `DeleteError`; already-deleted items stay deleted (no
      rollback), documented in the type and in README.
- [ ] Write tests (journal-asserted): data-only removes history dir + linked artifacts +
      exactly one JSON key with the project folder and other projects/unknown keys
      untouched; entirely additionally removes the folder; guards for
      empty/`/`/home/symlink/missing folder produce the documented verbatim warning +
      still clean data; orphan "entirely" degenerates without error; `dryRun` mutates
      nothing (journal has no `.removeItem`/`.writeData`) yet returns the same report as
      the real run; the fault hook makes a permission failure throw `DeleteError`;
      `listDirectory(home)` is never called and the exact removed-path set matches;
      `DeleteService` guard results agree with `ManagePlan.FolderStatus` for the same
      fixture home (pre-run signal and execution-time check cannot disagree).
- [ ] Run `swift test` — must pass before Task 5.

### Task 5: CLI `ccsync delete`

Files:

- Modify: `Sources/CCSyncCore/CLI.swift`
- Create: `Tests/CCSyncCoreTests/DeleteCLITests.swift` (or extend `CLIEndToEndTests.swift`)

- [ ] Extend `ArgParser` minimally with presence-only flags (`flagOptions: Set<String>` +
      `func flag(_ name:) -> Bool`) for `--orphans`, `--with-project-folder`, `--yes`
      (keeping the existing single-pass unknown-token rejection).
- [ ] Add `runDelete`: parse `--project <path> ...` (repeatable), `--orphans`,
      `--with-project-folder`, `--yes`. Build `ManagePlan` →
      `SelectionTree(managePlan:)`; select by `--project` path match (warn on an unknown
      path, as `runBackup` does) and/or all orphan nodes for `--orphans`; require at
      least one selector (usage error otherwise). `operation = --with-project-folder ?
      .entireProject : .claudeDataOnly`. `dryRun = !--yes`.
- [ ] Call `DeleteService.delete(selection:operation:dryRun:)`; print the `DeleteReport`
      as JSON via a new `deleteReportJSON` (symmetric with `reportJSON`, including
      `dryRun`, `deletedProjects`, `skippedProjects`, `warnings`); emit each warning to
      stderr; when dry-run, also print a stderr note that nothing was changed and `--yes`
      applies it.
- [ ] Register `case "delete"` in `run(...)` and extend the `usage` text with the
      `delete` grammar.
- [ ] Write end-to-end tests on `InMemoryFileSystem`: `--project` data-only dry-run
      changes nothing and prints the would-be report; the same with `--yes` produces the
      identical report and the asserted removed-path set; `--with-project-folder --yes`
      removes the folder too; `--orphans --yes` deletes orphan history dirs; no selector
      is a usage error; parity — the `--yes` CLI report equals a direct `DeleteService`
      run for the same selection (acceptance #5/#7).
- [ ] Run `swift test` — must pass before Task 6.

### Task 6: App Manage tab + irreversibility modal

Files:

- Modify: `App/CCSync/CCSyncApp.swift` (RootView picker → Backup / Restore / Manage)
- Create: `App/CCSync/ManageView.swift` (view + `ManageViewModel`)

- [ ] Add a `.manage` case to `RootView`'s `Tab` enum and a third segmented option;
      render `ManageView()` for it. Switching tabs must not reset the others (each view
      owns its `@StateObject`, as today).
- [ ] `ManageViewModel` mirrors `BackupViewModel`: `loadPlanIfNeeded()`/`reloadPlan()`
      building `SelectionTree(managePlan: ManagePlan(...))` off the main thread;
      `projectTree`, `folderState`, `toggleFolder`, `projectBinding` forwarding to Core
      (no global toggle, no visible master toggle — pass `projectsMasterOn: true` to the
      reused `ProjectSelectionTreeView`); a `folderCaption(_ encodedName:)` accessor
      forwarding to `ManagePlan.folderCaption`. Publish `operation: DeleteOperation`
      (default `.claudeDataOnly`), `isRunning`, and `report: DeleteReport?`.
- [ ] View: the reused grouped tree with all checkboxes off, each row additionally
      showing the Core folder caption when non-`nil` (pre-run signal: "folder already
      gone — Claude data only" etc.); a segmented operation picker ("Delete Claude data"
      / "Delete project entirely"); a destructive-styled "Delete…" button disabled while
      `isRunning` or `resolvedSelection().projectEncodedNames.isEmpty`.
- [ ] Irreversibility modal (`.confirmationDialog`/`.alert` with a `.destructive`-role
      confirm button, cancel default): state the deletion is permanent and irreversible
      with no snapshot/undo, enumerate N selected projects and the chosen operation, and
      — for "entirely" — the `ManagePlan.deletionSplit` counts: "N project folders will
      be deleted, M will have Claude data cleaned only." Only on confirm does it run
      `DeleteService.delete(..., dryRun: false)` off the main thread (mirror
      `performBackup`), then publish the `DeleteReport`.
- [ ] Report view: render `deletedProjects` (with folder-removed indicator),
      `skippedProjects` with reasons, and `warnings`, styled like `RestoreView`'s report.
      After a completed run, call `reloadPlan()` so deleted projects disappear from the
      list.
- [ ] Build gate: `xcodebuild -project App/CCSync.xcodeproj -scheme CCSync -configuration
      Debug CONFIGURATION_BUILD_DIR="$PWD/dist" build` must succeed.

### Task 7: Verify acceptance criteria

- [ ] Run `swift test` — full suite green, including the pre-existing 149 tests
      (Backup/Restore behaviour unchanged) plus the new Delete/Manage/FileSystem tests.
- [ ] Run the App build gate: `xcodebuild -project App/CCSync.xcodeproj -scheme CCSync
      -configuration Debug CONFIGURATION_BUILD_DIR="$PWD/dist" build`.
- [ ] Confirm each acceptance criterion is covered by a test: (1) data-only removes
      history + artifacts + one JSON key, folder untouched, other/unknown keys survive;
      (2) entirely removes the folder with the empty/`/`/home/symlink/missing guards and
      verbatim warnings; (3) orphans selectable and "entirely" on an orphan succeeds
      without error; (4) default Manage tree empty + Delete disabled + GUI gated behind
      the modal with the split counts; (5) CLI dry-run mutates nothing and `--yes` equals
      the GUI result; (6) journal asserts the exact removed-path set and no
      `listDirectory(home)`; pre-run `ManagePlan.FolderStatus` agrees with
      `DeleteService`'s execution-time guards.
- [ ] Manual walkthrough in the built app: select projects, check row captions for a
      missing-folder project, confirm the modal shows the N/M split, run a deletion on a
      throwaway project, verify the report and that the list reloads without it.

### Task 8: Update documentation

- [ ] README: add a "Manage tab" section and the `ccsync delete (--project <path> ... |
      --orphans) [--with-project-folder] [--yes]` grammar with the dry-run default; state
      deletion is permanent with no snapshot and no undo, and that a permission failure
      stops the run leaving already-deleted items deleted (no rollback); scope the
      existing snapshot policy explicitly to restore; document the folder-removal guards
      (unsafe path / symlink / missing) and best-effort semantics.
- [ ] CLAUDE.md: extend the Core contract with `DeleteService`/`DeleteReport`,
      `ManagePlan` (folder status, captions, `deletionSplit`), the
      `SelectionTree(managePlan:)` builder (all-selectable, default-off, no global
      layer), `FileSystem.removeItem` semantics, the shared artifact-discovery helper
      (one implementation for `BackupCollector` and `ProjectDataLocator`), and note the
      snapshot policy is restore-only (Manage never snapshots).
