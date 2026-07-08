# Backup selection (global + per-project), parity with Restore

## Overview

Backup gains the same selection model as Restore. Core adds `BackupPlan` (a mirror of `RestorePlan`, but sourced from the local machine), `SelectionTree(plan: BackupPlan)`, and selective collection `collect(selection:)` / `backup(to:selection:)`. The CLI gets flags `[--global|--no-global] [--projects|--no-projects] [--project <path> ...]`; the GUI renders the same tree of toggles. The archive format (CCSAR1) does not change, and — per the task boundary — the restore side is NOT touched.

Selection contract: `Selection` is the seam. `nil` means "everything selected" and exists ONLY for backward compatibility with existing `backup(to:)` / `collect()` call sites. Both GUI and CLI ALWAYS pass an explicit, non-nil `Selection` derived from `tree.resolvedSelection()` — they never rely on the `nil` default.

## Boundary guard (from review feedback — must hold during implementation)

- The restore side is explicitly out of scope. Do NOT modify `RestoreService` and do NOT change `report.globalRestored`, which today equals the restore-side `selection.global` regardless of whether the archive's global layer had any content.
- An archive with an empty global layer could already exist today (a backup taken on a machine where `~/.claude` is empty). Restoring such an archive with `selection.global == true` writes no global files (every write in `restoreGlobal` is guarded by `if let payload`) but still reports `globalRestored == true`. That is the existing, unchanged contract — this plan does not alter it, so no README report-semantics change is needed and existing restore tests stay green trivially.
- WATCH-ITEM: if, contrary to this design, any step forces a change to restore behavior or breaks an existing restore test around `globalRestored`, STOP and surface it as an observable-contract change (CLI report + README) rather than silently patching the test. Do not "fix" a test to make the suite green.

## Context

- Files involved:
  - Core: `Sources/CCSyncCore/BackupCollector.swift`, `BackupService.swift`, `SelectionTree.swift`, `RestorePlan.swift` (template only, not modified), `Model/BackupModel.swift` (`GlobalConfig`, read-only reference), `CLI.swift`.
  - Core (new): `Sources/CCSyncCore/ProjectInventory.swift`, `Sources/CCSyncCore/BackupPlan.swift`.
  - GUI: `App/CCSync/BackupView.swift` (BackupView + BackupViewModel), template — `RestoreView.swift` / `RestoreViewModel`.
  - Tests: `BackupPlanTests.swift` (new), `SelectionTreeTests.swift`, `BackupCollectorTests.swift`, `BackupServiceTests.swift`, `CLIEndToEndTests.swift`. (`RestoreServiceTests.swift` is NOT modified — restore side untouched.)
- Related patterns:
  - `RestorePlan` / `SelectionTree(plan: RestorePlan)` / `Selection` — the exact model to mirror.
  - `runRestore` in `CLI.swift`: order of application — first `--project` (reset all, enable named), then `--projects/--no-projects`; `resolvedSelection()` returns an empty set when the master is off, regardless of node marks. Backup must replicate this order.
  - `InMemoryFileSystem.journal` with `.readData` / `.writeData` / `.listDirectory` cases — the invariant gate (don't scan disk; don't read/write unselected).
  - `RestoreViewModel.chooseArchive()` do/catch + `errorMessage` — template for loading the plan in the GUI.
- Dependencies: none external. `swift test` is the gate.

## Key design decisions

- Shared part carries the on-disk fact explicitly. `ProjectInventory.list(claudeJSON:fileSystem:paths:) -> [ProjectInventory.Entry]` where `Entry = { path, encodedName, settings: JSONValue?, hasHistoryDir: Bool, incomplete: Bool, incompleteReason: String? }`. Returning `[ManifestProject]` would drop `hasHistoryDir` (that struct has no such field), forcing the collector to re-derive "is there a directory to read" from the reason string; the `Entry` type keeps the fact first-class. Sessions are NOT read.
- "Everything selected" by default: `collect(selection: Selection? = nil)` and `backup(to:selection: Selection? = nil)`, where `nil` = full backup. `Selection` is unchanged (invariant). Existing `collect()`/`backup(to:)` calls still compile and produce the previous result.
- Selectivity before reading: an unselected project is cut by `selection.projectEncodedNames.contains(encodedName)` in the loop before any `collectSessions`/`collectLocalSettings` call — filter the source, not the finished model.
- Global off → store an empty `GlobalConfig()`, `collectGlobal` is not called, `settings.json`/`CLAUDE.md`/config directories/`mcpServers` are not read. The resulting archive simply has no global payloads; restore of it is handled by the existing (untouched) `if let payload` guards.

## Development Approach

- **Testing approach**: Regular (implementation, then tests) — matches the repo style; every task includes new/updated tests.
- `swift test` is the gate: a green run is required before moving to the next task.
- Core invariants are honored: `FileSystem` only, no disk scanning; verified via the `InMemoryFileSystem` journal.
- Logic lives in Core; SwiftUI views stay dumb bindings (invariant #4).
- **CRITICAL: every task includes new/updated tests.**
- **CRITICAL: all tests green before starting the next task.**

## Implementation Steps

### Task 1: Core — ProjectInventory + BackupPlan

**Files:**
- Create: `Sources/CCSyncCore/ProjectInventory.swift`
- Create: `Sources/CCSyncCore/BackupPlan.swift`
- Modify: `Sources/CCSyncCore/BackupCollector.swift`
- Create: `Tests/CCSyncCoreTests/BackupPlanTests.swift`

- [ ] Add `ProjectInventory` with a public `Entry` `{ path, encodedName, settings: JSONValue?, hasHistoryDir: Bool, incomplete: Bool, incompleteReason: String? }` and `static func list(claudeJSON:fileSystem:paths:) -> [ProjectInventory.Entry]`: reads `projects` from `~/.claude.json`, lists `projectsDir` with the symlink guard (like `isListableDirectory`), forms the three matching cases (entry+dir → `hasHistoryDir true`; entry without dir → `hasHistoryDir false`, incomplete "no history directory on disk"; orphaned dir without entry → path "", `hasHistoryDir true`, incomplete "no entry in ~/.claude.json"). Session contents are NOT read.
- [ ] PRESERVE the current ordering from `collectProjects` (important for manifest stability and existing tests): first the entries from `~/.claude.json`, iterated by `projectSettings.keys.sorted()` (sorted by path); then orphaned dirs by `existingDirs.sorted()` (sorted by encoded name). `ProjectInventory.list` returns `Entry` in exactly this order; keep the symlink guard for orphaned dirs (skip non-listable).
- [ ] Switch `BackupCollector.collectProjects` to iterate `ProjectInventory.list(...)`, reading sessions only when `entry.hasHistoryDir == true`; the extracted common part, no duplication of matching logic. The resulting `[ProjectEntry]` (incl. order, `incomplete`/`incompleteReason`) matches current full-collect behavior byte-for-byte — existing `BackupCollectorTests` stay green without changing order expectations.
- [ ] Add `BackupPlan` (mirror of `RestorePlan`): fields `sourceUser`, `projects: [ManifestProject]`; `init(fileSystem:paths:sourceUser:)` reads `~/.claude.json` (same symlink guard), calls `ProjectInventory.list`, maps `Entry -> ManifestProject` (path/encodedName/settings/incomplete/incompleteReason, in the same order). `hasHistoryDir` is intentionally not carried into the plan (the plan never reads sessions).
- [ ] `BackupPlanTests` on `InMemoryFileSystem`: list composition and order (normal projects by sorted path, then orphans by sorted name; entry without dir; correct `incomplete`/reason) + journal assert: session contents were not read, `listDirectory(home)` was never called.
- [ ] `swift test` — green before Task 2.

### Task 2: Core — SelectionTree(plan: BackupPlan)

**Files:**
- Modify: `Sources/CCSyncCore/SelectionTree.swift`
- Modify: `Tests/CCSyncCoreTests/SelectionTreeTests.swift`

- [ ] Add `init(plan: BackupPlan)` modeled on `init(plan: RestorePlan)`: global on, master on, all projects selected; `Node` from `path`/`encodedName`/`incomplete`. Do not touch `Selection`.
- [ ] Test: `SelectionTree(plan: BackupPlan)` yields the "everything on" default and a correct `resolvedSelection()` (global true, all encodedName in the set).
- [ ] `swift test` — green before Task 3.

### Task 3: Core — selective collection + round-trip

**Files:**
- Modify: `Sources/CCSyncCore/BackupCollector.swift`
- Modify: `Sources/CCSyncCore/BackupService.swift`
- Modify: `Tests/CCSyncCoreTests/BackupCollectorTests.swift`
- Modify: `Tests/CCSyncCoreTests/BackupServiceTests.swift`

- [ ] `BackupCollector.collect(selection: Selection? = nil)`: `nil` → full backup (backward-compat default only); otherwise filter projects by `encodedName` BEFORE reading sessions/local settings (`selection.projectEncodedNames.contains(encodedName)` inside the loop, not filtering the finished model); when `selection.global == false` do not call `collectGlobal`, store an empty `GlobalConfig()`.
- [ ] `BackupService.backup(to:selection: Selection? = nil)` forwards the selection to the collector; the existing `backup(to:)` signature keeps working (backward-compat only).
- [ ] Do NOT modify `RestoreService` (see Boundary guard). `report.globalRestored` semantics are unchanged.
- [ ] Test `collect(selection:)` in `BackupCollectorTests`: an unselected project's paths are absent from the journal (`.readData`); with global off the global paths (`settings.json`, `CLAUDE.md`, config dirs) were not read, `mcpServers` did not make it into the model.
- [ ] Round-trip of a selective archive (one project) in `BackupServiceTests`: opens via `RestorePlan`, restores via `RestoreService`; the archive lacks the unselected project's paths (checked through `RestorePlan`/reader), the selected project is restored.
- [ ] Round-trip of an archive WITHOUT a global layer (collected with `global == false`), restored with `selection.global == true` on a non-empty fixture home, asserting only what the untouched restore side actually guarantees:
  - `XCTAssertFalse(fs.journal.contains(.writeData(...)))` for EVERY global path — `~/.claude/settings.json`, `~/.claude/CLAUDE.md`, files inside `globalConfigDirNames`, and no `~/.claude.json` write via the global `mcpServers` merge — i.e. an empty global layer never clobbers a live config;
  - the selected project is still restored correctly (positive control that restore ran through the global branch);
  - `report.globalRestored` remains `true` (it reflects the restore-side `selection.global`, not backup content) — assert this explicitly to document the unchanged contract. Do NOT assert it `false`.
- [ ] `swift test` — green before Task 4.

### Task 4: CLI — backup flags

**Files:**
- Modify: `Sources/CCSyncCore/CLI.swift`
- Modify: `Tests/CCSyncCoreTests/CLIEndToEndTests.swift`

- [ ] `runBackup`: parse `[--global|--no-global] [--projects|--no-projects] [--project <path> ...]` via the existing `boolFlag`/`repeatedOptionValues`; build `BackupPlan(fileSystem:paths:)`, `SelectionTree(plan:)`, apply flags in the SAME order as `runRestore` (first `--project` → reset all + enable by path match with a warning on unknown path; then `--global`, then `--projects`), and ALWAYS pass an explicit `tree.resolvedSelection()` into `backup(to:selection:)` (never `nil`).
- [ ] No flags → full backup, produced via the default (all-on) tree resolved to an explicit `Selection` — not via the `nil` default.
- [ ] Update `usage` for `backup`.
- [ ] Tests: parsing of the new flags, conflicting/edge combinations (`--global --no-global`, dangling `--project`, `--project` with an unknown path), equivalence of "no flags" to a full backup; verify unselected content did not make it into the archive (via `RestorePlan` over the result).
- [ ] Test `--no-projects --project <path>` (parity with restore): a disabled master gates the whole set — the resulting `resolvedSelection().projectEncodedNames` is empty despite `--project`; the produced archive contains no projects (checked via `RestorePlan`), the global layer is present. Result is equivalent to `--no-projects` without `--project` — `--project` is inert when the master is off (exactly like `runRestore`).
- [ ] `swift test` — green before Task 5.

### Task 5: GUI — BackupView/BackupViewModel

**Files:**
- Modify: `App/CCSync/BackupView.swift`

- [ ] `BackupViewModel`: `@Published private(set) var tree: SelectionTree?`, `@Published private(set) var errorMessage: String?`, a private `didLoadPlan` guard. `loadPlanIfNeeded()` (no-op if already loaded) and `reloadPlan()` (reset guard, clear `tree`/`errorMessage`, rebuild). Both build `BackupPlan` off the main thread (`Task.detached`, `RealFileSystem`/`NSHomeDirectory`/`KnownPaths`), then publish `tree = SelectionTree(plan:)` on the main actor; on error — set `errorMessage`, `tree = nil` (modeled on `RestoreViewModel.chooseArchive()`). Forwarding bindings as in `RestoreViewModel` (`globalBinding`, `projectsMasterBinding`, `projectBinding(_:)`, `projectRows`, `projectsMasterOn`) — pure forwarders, no logic.
- [ ] `BackupView`: `.onAppear { model.loadPlanIfNeeded() }` — the plan is built once on first appearance and is not rebuilt when switching Backup↔Restore (guard against reset-on-tab-switch). A "Refresh" button in the header → `model.reloadPlan()` (disabled while `isRunning`). The same selection block as `RestoreView`, shown only when `tree != nil` (Global config, Projects master, per-project rows labeled "incomplete"); when `tree == nil` without error — "Reading local config…"; `errorMessage` — a red `Label` GroupBox as in `RestoreView`.
- [ ] `run()` ALWAYS passes an explicit `tree.resolvedSelection()` into `BackupService.backup(to:selection:)`; the guard makes it a no-op while `isRunning` or when `tree == nil`, so a `nil` selection is never passed. Keep the existing destination choice and off-main-thread execution.
- [ ] Note: GUI tests are not required (all logic is covered in Core); building the app is not part of the automatable checkboxes.

### Task 6: Verify acceptance criteria

- [ ] `swift test` — full run green.
- [ ] `swift build` — the package builds.
- [ ] Confirm coverage of every spec test point: BackupPlan journal + order, collect journal (unselected project + global off), SelectionTree default, CLI flags (incl. conflicts and `--no-projects --project`), selective round-trip, no-global round-trip (no global writes + project restored + `globalRestored` stays `true`).
- [ ] Confirm the restore side was not modified (no diff in `RestoreService.swift` / `RestoreServiceTests.swift`).

### Task 7: Update documentation

- [ ] README.md, "CLI usage" section: document `ccsync backup [--global|--no-global] [--projects|--no-projects] [--project <path> ...]` with the same semantics as restore; note that no flags = full backup. Do NOT change any restore-report wording (the report contract is unchanged).
- [ ] CLAUDE.md: add `BackupPlan`/`ProjectInventory` to the Core types list; note in "Core contract" that backup now also accepts a `Selection` (with `nil` reserved as a backward-compat "select all" default that GUI/CLI never use). No change to the restore/`globalRestored` description.

## Post-Completion (manual)

- Run the DoD scenario by hand: from GUI and CLI, build a single-project archive without global, restore on another machine / in a fixture, confirm correctness.
- In the GUI, check the tab-switch case: deselect some projects on Backup, switch to Restore and back — the selection must persist (no reset); "Refresh" rebuilds the tree on demand.
