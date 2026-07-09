# Tree view visual fix: aligned rows, segment labels, guide lines

## Overview

Presentation-only rework of the grouped project tree renderer. Three visual defects get fixed: leaf rows showing full absolute paths (redundant, drives misalignment), DisclosureGroup center-alignment "staircase", and unreadable nesting depth. The fix flattens `ProjectPathTree` into leading-aligned, full-width rows with classic tree-view guide lines, and shows only the last path segment per leaf. No selection semantics change — same `ProjectPathTree`, same `projectBinding`/`folderState`/`toggleFolder` closures, same gating, same orphan section, same Manage captions.

## Context

- Files involved:
  - Modify: `App/CCSync/ProjectSelectionTreeView.swift` — the rework (flattened render, guide lines, segment labels).
  - Modify: `Sources/CCSyncCore/ProjectPathTree.swift` — add `Leaf.name` display field (last path segment).
  - Modify: `Tests/CCSyncCoreTests/ProjectPathTreeTests.swift` — cover `Leaf.name`.
- Related patterns:
  - `ProjectPathTree.Leaf` already carries display-only fields (`path`, `encodedName`, `incomplete`, `incompleteReason`, `incompleteSummary`, `isSelectable`) and no `isSelected` — `name` joins them.
  - `ProjectPathTree.lastSegment(_:)` already exists (private) and is the exact derivation to reuse for `name`.
  - `ProjectPathTree.Row` is already `Identifiable` with a stable, non-colliding `id: String` (folder → `pathPrefix`, project → `encodedName`) — the flattened `ForEach` keys on this, never on array indices.
  - The view is consumed unchanged by `BackupView.swift:104`, `RestoreView.swift:77`, `ManageView.swift:74` — all three pick up the fix automatically.
- Dependencies: none new. AppKit `Color(nsColor: .separatorColor)` for guide-line color (macOS-only target, already SwiftUI on AppKit).

## Development Approach

- **Testing approach**: Regular for the view (SwiftUI, no unit harness — verified by the xcodebuild gate and manual screenshots); TDD-style for the one Core field (`Leaf.name`) since it is unit-testable.
- Complete each task fully before the next; `swift test` must be green before moving on.
- **CRITICAL: every code task includes new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- Selection behaviour is verbatim: tri-state folder checkbox images/tap semantics, expansion default `map[id] ?? true`, `isRunning`/master/`isSelectable` gating, incompleteness captions, Manage's `leafCaption`, folder-checkbox accessibility label/value, and real Button/Toggle controls (keyboard-focusable — no tap gestures for selection).

## Implementation Steps

### Task 1: Add `Leaf.name` display field in Core

**Files:**
- Modify: `Sources/CCSyncCore/ProjectPathTree.swift`
- Modify: `Tests/CCSyncCoreTests/ProjectPathTreeTests.swift`

- [x] Add a stored `public var name: String` to `ProjectPathTree.Leaf`, initialized in `init`, documented as "the last path segment (display label); empty for orphans, which render `encodedName` instead".
- [x] Populate it in `makeLeaf(_:)` as `lastSegment(node.path)` when `path` is non-empty, else `""` (orphans keep using `encodedName` in the orphan section).
- [x] Update the `Leaf(...)` constructions in the test helpers so they compile with the new field.
- [x] Add tests: a normal project leaf's `name` equals its final segment (e.g. `/Users/a/git/bocore` → `bocore`); a project-is-also-a-prefix leaf keeps its own segment; an orphan leaf's `name` is `""`.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: Flatten the tree and render aligned rows with guide lines

**Files:**
- Modify: `App/CCSync/ProjectSelectionTreeView.swift`

- [ ] Replace the recursive `DisclosureGroup`/`TreeRow` structure with a flatten step: walk `tree.roots` (respecting the `expanded` map, `map[id] ?? true`) into an ordered array of visible render rows. Each render row carries: the underlying `ProjectPathTree.Row` (folder or leaf), `depth`, `isLastSibling`, and per-ancestor-level continuation flags (whether each ancestor level still has a following sibling — drives which vertical guide lines to draw).
- [ ] Stable row identity: the flattened `ForEach` keys on the row's underlying `ProjectPathTree.Row.id` (folder `pathPrefix` / project `encodedName`), never on array offsets. If the render-row wrapper struct is made `Identifiable`, its `id` forwards that `Row.id` verbatim. Keying on indices would let a collapse/expand recycle a row struct onto a different node — reordering identity, animating the wrong rows, and disturbing the `expanded` state; keying on the node id keeps each row pinned to its node across expansion changes.
- [ ] Render each visible row as a single leading-aligned, full-width `HStack`: guide-line columns (one fixed-width cell per depth level) → chevron (folders only, a real `Button` toggling the expansion binding) → selection control (folder tri-state `Button` / leaf `Toggle`) → label. No centered content anywhere.
- [ ] Chevron accessibility: the separate chevron `Button` gets a distinct label so it does not read identically to the adjacent tri-state checkbox (which keeps `accessibilityLabel(folder.label)`). Use a disambiguated label of the form `"\(folder.label), expand"` / `"\(folder.label), collapse"` (state-dependent on `isExpanded`), so VoiceOver announces two distinctly-named, stateful controls per folder rather than two controls with the same name back-to-back — the announcement `DisclosureGroup` gave us for free must not regress. Keep it a real focusable `Button`, not a tap gesture.
- [ ] Guide lines: per depth level a fixed-width cell (uniform indent step 16–20 pt). Draw a 1 pt vertical line in `Color(nsColor: .separatorColor)` for each ancestor level that still has a following sibling; draw the row's own connector (vertical segment + short horizontal tick into the row) using `isLastSibling` to pick corner vs. T-junction. Keep it as a small dedicated guide-column subview so the `HStack` stays readable.
- [ ] Label truncation: preserve today's `.lineLimit(1).truncationMode(.middle)` on the folder label (a compacted, possibly long absolute prefix like `/Users/antonkarmanov/git` can overflow a narrow window) and apply the same to the leaf label as a safeguard — the flattened render must not drop the existing truncation behaviour.
- [ ] Leaf label: show `leaf.name` (last segment) leading-aligned, `.help(leaf.path)` for the full path as tooltip. Keep `incompleteSummary` caption and the Manage `leafCaption` beneath, greyed/`.orange` exactly as today; keep `.disabled(isRunning || !projectsMasterOn || !leaf.isSelectable)`.
- [ ] Folder header: keep the tri-state `Button` (images `checkmark.square.fill`/`square`/`minus.square.fill`, tap on→off / off·mixed→on via `toggleFolder`), `.disabled(isRunning || !projectsMasterOn)`, `.accessibilityLabel(folder.label)` + `.accessibilityValue`, and show `folder.label` leading-aligned. The chevron is a separate `Button` driving the expansion binding (expand/collapse stays independent of the checkbox).
- [ ] Orphan section unchanged: keep the "History only — no project entry" header and render each orphan with the existing leaf row showing `encodedName` (path is empty), same gating.
- [ ] Update the file's doc comment to describe the flattened render + guide lines and to drop the `DisclosureGroup`/middle-truncated-path description.

### Task 3: Verify acceptance criteria

**Files:** none (verification only)

- [ ] Run `swift test` — full suite green (including the new `Leaf.name` tests).
- [ ] Run the canonical Debug xcodebuild gate: `xcodebuild -project App/CCSync.xcodeproj -scheme CCSync -configuration Debug CONFIGURATION_BUILD_DIR="$PWD/dist" build` — must succeed (builds into `dist/CCSync.app` for the manual screenshot check).

### Task 4: Update documentation

**Files:**
- Modify: `CLAUDE.md` (only if the grouped-tree contract wording needs it)

- [ ] Update the "Grouped project tree" contract paragraph in `CLAUDE.md` to note `Leaf` now also carries `name` (last path segment, display-only, still no `isSelected`) and that the shared view renders a flattened, guide-lined, leading-aligned tree showing segment labels with the full path as a tooltip.

## Post-Completion (manual, not agent-automatable)

- Capture before/after screenshots of the Backup tab (from `dist/CCSync.app`) and attach them to the PR (acceptance #5 — this task is the visual result).
- Sanity-check collapse/expand, tri-state toggling, and gating in the running app across Backup / Restore / Manage, and verify VoiceOver announces each folder's chevron and checkbox as two distinctly-named, stateful controls.
