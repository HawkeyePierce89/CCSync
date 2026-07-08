# Project list scroll + human-readable label instead of «incomplete backup»

## Overview

A targeted UX fix for two screens (Backup/Restore) with no redesign. Core: carry `ManifestProject.incompleteReason` through to `SelectionTree.Node` and add a computed `incompleteSummary` property with a human-readable mapping (invariant #4 — one wording for both screens, covered by `swift test`). GUI: replace the hardcoded «incomplete backup» with `incompleteSummary`, wrap each screen's selection block in a `ScrollView`, and bound the Restore `ReportView` so a long restore report scrolls internally instead of pushing the Run button off-screen.

## Context

- Core (modify):
  - `Sources/CCSyncCore/SelectionTree.swift` — add field `incompleteReason: String?` to `Node` (memberwise init with default `nil`), computed `incompleteSummary: String?`, and pass `$0.incompleteReason` through in both builders `init(plan: RestorePlan)` and `init(plan: BackupPlan)`.
- Data source (do not touch): `ManifestProject.incompleteReason` is already populated in `ProjectInventory.swift` («no history directory on disk» / «no entry in ~/.claude.json»); `RestorePlan.projects` and `BackupPlan.projects` are `[ManifestProject]`, the field is already present.
- GUI (modify):
  - `App/CCSync/BackupView.swift` — `selection` view; the `Text("incomplete backup")` line; the `body` (VStack) to wrap the selection in a ScrollView. Backup's result block is a single bounded GroupBox (no ForEach), so it needs no scroll.
  - `App/CCSync/RestoreView.swift` — same label + selection-scroll changes, plus `ReportView` (a `GroupBox("Result")` with `ForEach` over `restoredProjects`/`skippedProjects`/`warnings`) which can grow with 50 restored projects and push the Run button off-screen; bound it with an internal scroll.
- Tests: `Tests/CCSyncCoreTests/SelectionTreeTests.swift`. Current fixtures: `samplePlan()` (RestorePlan) uses reason `"directory missing"` (an unknown string), `sampleBackupPlan()` (BackupPlan) uses `"no history directory on disk"`. Neither carries `"no entry in ~/.claude.json"` through a plan builder — see Task 1 for the fixture adjustment so both known mappings are exercised on the real plan→tree path.
- Other `Node(...)` constructors — only the two internal builders in SelectionTree.swift; no external call sites.
- Related patterns: `SelectionTree` owns selection presentation logic (invariant #4 — views stay dumb); the mapping lives in Core.
- Dependencies: none (no new external dependencies).

## Development Approach

- **Testing approach**: Regular (Core code first, then tests in the same task).
- Boundaries: do not touch resolvedSelection/mutations, archive format, raw reason strings in the manifest and the `ccsync list` JSON contract, CLI output, restore semantics. Only presentation changes.
- Gate: `swift test` green; app builds via xcodebuild.
- **CRITICAL: every code-changing task includes tests; all tests pass before the next task.**

## Implementation Steps

### Task 1: Core — carry the reason and add the human-readable wording

**Files:**
- Modify: `Sources/CCSyncCore/SelectionTree.swift`
- Modify: `Tests/CCSyncCoreTests/SelectionTreeTests.swift`

- [x] Add field `public var incompleteReason: String?` to `SelectionTree.Node` (raw reason, for mapping).
- [x] Update the memberwise `Node.init` — parameter `incompleteReason: String? = nil` (default keeps compatibility for any future direct calls).
- [x] Add computed `public var incompleteSummary: String?` with an explicit contract — the incomplete signal must never be silently lost:
  - if `!incomplete` → `nil`;
  - `incomplete` && reason == `"no history directory on disk"` → `"settings only — no session history"`;
  - `incomplete` && reason == `"no entry in ~/.claude.json"` → `"history only — no project settings"`;
  - `incomplete` && reason is a non-empty unknown string → return the reason as-is;
  - `incomplete` && `incompleteReason == nil` (or empty) → generic fallback `"incomplete backup"` (never `nil` while `incomplete == true`).
- [x] In `init(plan: RestorePlan)` and `init(plan: BackupPlan)` pass `incompleteReason: $0.incompleteReason` when constructing `Node`.
- [x] Fixture prerequisite: ensure both known reasons flow through the real plan builders, not just direct Node construction. Currently `samplePlan()` (RestorePlan) uses `"directory missing"` and `sampleBackupPlan()` (BackupPlan) uses `"no history directory on disk"` — so `"no entry in ~/.claude.json"` is never carried by a plan. Adjust the fixtures so that across the two plans both real reason strings appear (e.g. give the RestorePlan Ghost node `"no entry in ~/.claude.json"` — the orphaned-directory case — while the BackupPlan keeps `"no history directory on disk"` — the entry-without-directory case). Keep the existing `.incomplete == true` assertions intact (mechanical value change only).
- [x] SelectionTreeTests: reason is carried through both constructors (RestorePlan and BackupPlan) — assert `incompleteReason` on each plan's incomplete (Ghost) node equals the fixture reason, confirming both real reason strings survive the plan→tree path.
- [x] SelectionTreeTests: `incompleteSummary` — assert both known mappings resolve to their human wording via the plan builders (`"no history directory on disk"` → `"settings only — no session history"`, `"no entry in ~/.claude.json"` → `"history only — no project settings"`), plus fallback to an unknown reason (returned as-is) and `nil` for a complete project.
- [x] SelectionTreeTests: dedicated fallback assertion — a node with `incomplete == true` and `incompleteReason == nil` yields the generic `"incomplete backup"` (never `nil`), so the orange label never silently disappears.
- [x] Review existing SelectionTreeTests assertions; update mechanically if the fixture reason change affects any (meaning unchanged).
- [x] `swift test` — green before Task 2.

### Task 2: GUI — incompleteSummary label + list scroll + bounded restore report

**Files:**
- Modify: `App/CCSync/BackupView.swift`
- Modify: `App/CCSync/RestoreView.swift`

- [x] BackupView: in `selection` replace `if row.incomplete { Text("incomplete backup")... }` with rendering `row.incompleteSummary` (`if let summary = row.incompleteSummary { Text(summary)... }`), keeping `.font(.caption2).foregroundStyle(.orange)`.
- [x] RestoreView: same replacement in `selection`.
- [x] BackupView: wrap the selection block (Global/Projects toggles + project `ForEach`) in a `ScrollView`; outside the scroll and always visible — header, description, destinationRow, runRow, result/error block.
- [x] RestoreView: wrap the selection block (sourceSummary + Global/Projects toggles + project `ForEach`) in a `ScrollView`; outside the scroll — header, runRow, ReportView/error. Note `runRow` renders before the report, so keeping Run outside the selection scroll keeps it visible above the report.
- [x] RestoreView: bound the long-report case — `ReportView` renders `ForEach` over `restoredProjects`/`skippedProjects`/`warnings`, which with ~50 projects grows past the window. Wrap the report content in a `ScrollView` with a capped `.frame(maxHeight:)` (e.g. ~240pt) so the report scrolls internally and never pushes the Run button off-screen. Keep the `GroupBox("Result")` framing and existing labels/styling.
- [x] Ensure the layout allows the selection ScrollView to compress vertically (Run and result do not slide off-screen with a long list; adjust `Spacer`/`frame` if needed without restructuring the screens).
- [x] `swift test` — green (Core untouched, regression check).

### Task 3: Verify acceptance criteria

- [ ] `swift test` — full suite green.
- [ ] App build: `xcodebuild -project App/CCSync.xcodeproj -scheme CCSync -configuration Debug CONFIGURATION_BUILD_DIR="$PWD/dist" build` passes.

## Post-Completion (manual verification)

- On a machine with a long project list: the Run button is visible without resizing the window, and the list scrolls with wheel/trackpad in both Backup and Restore.
- After restoring ~50 projects: the Restore result report stays bounded (scrolls internally) and the Run button remains visible without resizing the window.
- Instead of «incomplete backup» — a clear label distinguishing «no history» from «no settings», identical on both screens; a project flagged incomplete with no reason still shows the generic label rather than nothing.
