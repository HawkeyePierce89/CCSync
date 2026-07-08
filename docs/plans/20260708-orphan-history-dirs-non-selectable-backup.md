# Orphaned history directories — greyed out and non-selectable in Backup

## Overview

Orphaned history directories (`~/.claude/projects/<encoded>/` with no entry in `~/.claude.json`, whose `path == ""`) are currently selectable and enabled by default on the Backup screen, so they end up in the archive. Goal: mark such nodes as non-selectable in Core (structurally, by `path.isEmpty`) so the default backup tree excludes them from both GUI and CLI. In the GUI the row renders greyed out with a disabled, off toggle. The Restore screen is unaffected — orphan projects from old archives remain selectable and restorable.

## Context

- Files involved:
  - `Sources/CCSyncCore/SelectionTree.swift` — add `isSelectable` to `Node`, set it in both builders, guard `setProject`.
  - `App/CCSync/BackupView.swift` and `App/CCSync/RestoreView.swift` — the row render reads `isSelectable` (data-driven; both screens edited identically; Restore nodes are always `isSelectable == true`, so its behaviour does not change).
  - `Tests/CCSyncCoreTests/SelectionTreeTests.swift` — new unit tests.
  - `Tests/CCSyncCoreTests/CLIEndToEndTests.swift` — test "full backup with no flags does not contain orphan".
  - `README.md` ("Selection semantics" section) and `CLAUDE.md` (backup-selection contract).
- Related patterns:
  - The orphan criterion is already structural in the data: `ProjectInventory`/`BackupPlan` give an orphan `path == ""`, `incompleteReason == "no entry in ~/.claude.json"`. Use `path.isEmpty`, not the reason string.
  - The existing `sampleBackupPlan` "Ghost" has a non-empty path (`incompleteReason: "no history directory on disk"`) — it is NOT an orphan, stays selectable; existing tests do not break.
  - `BackupServiceTests` builds `Selection` directly (not via the tree), so explicit collection of an orphan still works — only default-tree resolution changes.
- Dependencies: none external.

## Development Approach

- **Testing approach**: TDD — failing Core tests first, then implementation; for CLI and GUI the test/build goes together with the change.
- `Node`'s memberwise `init` gets `isSelectable: Bool = true` (the default preserves backward compatibility for all existing call sites).
- Each task ends with a green `swift test` before the next.
- **CRITICAL: every task includes new/updated tests; all tests green before moving on.**

## Implementation Steps

### Task 1: Core — selectability flag in SelectionTree

**Files:**
- Modify: `Sources/CCSyncCore/SelectionTree.swift`
- Modify: `Tests/CCSyncCoreTests/SelectionTreeTests.swift`

- [x] In `SelectionTree.Node` add a public field `isSelectable: Bool` with documentation; in the memberwise `init` add a parameter `isSelectable: Bool = true` (last, so existing calls don't break) and assign it.
- [x] `init(plan: BackupPlan)`: for a node with `$0.path.isEmpty` build `Node(..., isSelected: false, ..., isSelectable: false)`; for others — as now (`isSelected: true`, `isSelectable: true`).
- [x] `init(plan: RestorePlan)`: all nodes `isSelectable: true` (behaviour unchanged, including orphan projects from the archive).
- [x] `setProject(encodedName:_:)`: after finding the index — `guard projects[index].isSelectable else { return }` (no-op for a non-selectable node); do not change `resolvedSelection()`.
- [x] Write/update tests in `SelectionTreeTests.swift`:
  - orphan backup-plan fixture (project with `path: ""`, `incompleteReason: "no entry in ~/.claude.json"`): node `isSelectable == false` and `isSelected == false`; a normal project — `isSelectable == true`, `isSelected == true`.
  - `setProject(encodedName: <orphan>, true)` on the default backup tree — node state does not change (no-op).
  - `resolvedSelection()` of the default backup tree does not contain the orphan name.
  - `SelectionTree(plan: RestorePlan)` with an orphan project from the archive: node `isSelectable == true`, `isSelected == true`, and `resolvedSelection()` contains it (regression — behaviour unchanged).
- [x] `swift test` — green before Task 2.

### Task 2: CLI — pin the consequence (default-backup test)

**Files:**
- Modify: `Tests/CCSyncCoreTests/CLIEndToEndTests.swift`

- [x] Add a test: seed a local home with one normal project (entry in `~/.claude.json` + history) and one orphan history directory (no entry). Run a full `backup` with no flags, then `RestorePlan` over the result → the project list contains the normal project and does NOT contain the orphan name.
- [x] Confirm the existing round-trip of an old archive containing an orphan project through `restore` stays green (do not change — just verify); add an explicit reference/assert if helpful, but without changing restore semantics.
- [x] `swift test` — green before Task 3.

### Task 3: GUI — greyed-out, disabled render of non-selectable rows

**Files:**
- Modify: `App/CCSync/BackupView.swift`
- Modify: `App/CCSync/RestoreView.swift`

- [ ] In both screens inside `ForEach(model.projectRows…)`:
  - row toggle — `.disabled(model.isRunning || !model.projectsMasterOn || !row.isSelectable)` (the "Projects" master does not affect non-selectable rows: they are always disabled).
  - name/path `Text(...)` — `.foregroundStyle(row.isSelectable ? .primary : .secondary)`.
  - `incompleteSummary` caption — colour `row.isSelectable ? .orange : .secondary` (turn the orange caption grey for non-selectable rows).
- [ ] Edits are identical in both files; since Restore nodes are always `isSelectable == true`, RestoreView is visually unchanged.
- [ ] Build the app: `xcodebuild -project App/CCSync.xcodeproj -scheme CCSync -configuration Debug CONFIGURATION_BUILD_DIR="$PWD/dist" build` — succeeds.

### Task 4: Verify acceptance criteria

- [ ] `swift test` — the whole suite green.
- [ ] `xcodebuild -project App/CCSync.xcodeproj -scheme CCSync -configuration Debug CONFIGURATION_BUILD_DIR="$PWD/dist" build` — build succeeds.
- [ ] Confirm data is untouched: directories under `~/.claude/projects/` are not deleted and not hidden from `BackupPlan` (the orphan still appears in the list, just non-selectable); archive format, restore semantics, `ProjectInventory` unchanged.

### Task 5: Update documentation

- [ ] `README.md` ("Selection semantics" section): extend the incomplete bullet to state that orphaned history directories (`projects/<encoded>/` with no entry in `~/.claude.json`) are listed in the GUI as non-selectable (greyed out, toggle off) and are not included in the archive.
- [ ] `CLAUDE.md` (the "Backup selection" contract): record that the default backup tree does not include orphan nodes (`path.isEmpty` → `isSelectable == false`, `isSelected == false`); `setProject` is a no-op for a non-selectable node; on the restore side behaviour is unchanged (orphan from an archive is selectable).
