# Grouped collapsible project tree for Backup and Restore screens — work plan

Issue: [#8 add tree view for paths](https://github.com/HawkeyePierce89/CCSync/issues/8)

## Overview

Render the project selection on both the Backup and Restore screens as a collapsible,
path-grouped tree instead of a flat list of absolute paths — with compacted single-child
folder chains, tri-state folder checkboxes, and a dedicated orphan section. This is a
presentation-only change: `SelectionTree` remains the flat source of truth, and
`resolvedSelection()`, the archive format, and the CLI are untouched. A new Core type
derives the tree; the SwiftUI views stay dumb renderers over it.

## Context

- Files involved:
  - `Sources/CCSyncCore/SelectionTree.swift` — add tri-state enum + folder
    cascade/derivation helpers alongside `setProject`.
  - `Sources/CCSyncCore/ProjectPathTree.swift` (new) — the tree-derivation type.
  - `App/CCSync/BackupView.swift`, `App/CCSync/RestoreView.swift` — swap the flat
    `ForEach` for the grouped renderer; add three model accessors each.
  - `App/CCSync/ProjectSelectionTreeView.swift` (new) — shared recursive SwiftUI renderer.
  - `Tests/CCSyncCoreTests/ProjectPathTreeTests.swift` (new) —
    grouping/compaction/cascade/orphan/master-off coverage.
  - `Tests/CCSyncCoreTests/SelectionTreeTests.swift` — add folder-helper tests.
  - `CLAUDE.md`, `README.md` — docs.
- Related patterns: `SelectionTree.Node` (identity = `encodedName`, `path.isEmpty` =
  orphan), existing `setProject` no-op-for-non-selectable rule, existing
  bindings-forward-to-Core view-model style.

## Locked design decisions (documented rules)

- **Grouping:** split each non-orphan `path` on `/` (drop leading empty). Final segment =
  project leaf; preceding segments = folders. Build a trie of leaves.
- **Compaction:** a folder that is not itself a project and has exactly one child folder
  merges its label with that child (joined by `/`), repeated. Compaction stops at a leaf
  child, a multi-child folder, or a folder that is a project. Root folder labels are
  prefixed with `/` to read as absolute (e.g. `/Users/alice`).
- **Project-is-also-a-prefix:** when a trie node is both a project and has descendants,
  emit two sibling rows — the project as a leaf, then a folder of the same name holding
  the descendants. Leaf sorts before its same-named sibling folder.
- **Child ordering:** within a folder, children are sorted case-insensitively by label
  (leaf-before-same-named-folder tiebreak).
- **Orphans (`path.isEmpty`):** collected into `orphans`, rendered after the tree, showing
  `encodedName` — never placed in the hierarchy.
- **Tri-state:** a folder's `descendantEncodedNames` = all leaf encoded names in its
  subtree; state = on (all selected) / off (none) / mixed. Toggling routes each descendant
  through `setProject`, so non-selectable leaves are never flipped and master-off still
  resolves empty.
- **Single source of selection truth:** the derived tree carries **no selection state**.
  `Leaf` holds only display fields (`path`, `encodedName`, `incomplete`,
  `incompleteReason` / `incompleteSummary`, `isSelectable`) — deliberately **not**
  `isSelected` and not the whole `Node`, so a renderer *cannot* bind a checkbox to stale
  data. All selection reads/writes go through the live `SelectionTree` (`projectBinding`,
  `folderState`, `setFolder`).
- **Unknown names are ignored:** `folderState` skips encoded names not present in the
  tree when deriving state (a list of only-unknown names derives `.off`); `setFolder`
  routes through `setProject`, which already no-ops on unknown names. Covered by a test —
  the name list travels from a derived structure and may in theory lag the tree.
- **Folder rows obey the same gating as leaves:** a folder checkbox is disabled when
  `isRunning || !projectsMasterOn`. No folder may be toggleable while the leaves under it
  are disabled.

## New Core signatures

```swift
// SelectionTree.swift
public enum FolderCheckState: Equatable, Sendable { case on, off, mixed }

extension SelectionTree {
    func folderState(descendantEncodedNames: [String]) -> FolderCheckState
    mutating func setFolder(descendantEncodedNames: [String], _ on: Bool)
}

// ProjectPathTree.swift
public struct ProjectPathTree: Equatable, Sendable {
    public indirect enum Row: Equatable, Sendable, Identifiable {
        case folder(Folder), project(Leaf)
        public var id: String   // folder: pathPrefix, leaf: encodedName
    }
    public struct Folder: Equatable, Sendable {
        public var label: String
        public var pathPrefix: String
        public var descendantEncodedNames: [String]
        public var children: [Row]
    }
    public struct Leaf: Equatable, Sendable {
        // Display-only: no isSelected on purpose (single source of truth
        // stays in SelectionTree; read selection via projectBinding/folderState).
        public var path: String
        public var encodedName: String
        public var incomplete: Bool
        public var incompleteReason: String?
        public var isSelectable: Bool
        public var incompleteSummary: String? // same wording as SelectionTree.Node
    }
    public var roots: [Row]
    public var orphans: [Leaf]
    public init(nodes: [SelectionTree.Node])
}
```

## Development Approach

- Testing approach: TDD for the two Core tasks (write failing tests first); regular for
  the App renderer (verified by the `xcodebuild` gate + acceptance walkthrough — SwiftUI
  views are not unit-tested here, matching the repo's existing split).
- Complete each task fully — `swift test` green — before the next.
- Every code task includes tests except the App renderer, which is covered by the build
  gate.

## Implementation Steps

### Task 1: Core — ProjectPathTree derivation type

Files:

- Create: `Sources/CCSyncCore/ProjectPathTree.swift`
- Create: `Tests/CCSyncCoreTests/ProjectPathTreeTests.swift`

- [x] Write failing tests: acceptance-1 shape (`/Users/a/git/x`, `/git/y`, `/work/z` →
      single `/Users/a` root, `git` + `work` folders, three leaves); single-child
      compaction of a lone project chain; project-is-also-a-prefix (leaf + same-named
      sibling folder, leaf first); child ordering; orphan placement (`path.isEmpty` lands
      in `orphans`, not `roots`); `descendantEncodedNames` completeness per folder;
      Leaf carries the display fields verbatim from the source `Node` (including
      `isSelectable` and the `incompleteSummary` wording) and has no selection state.
- [x] Implement `ProjectPathTree(nodes:)`: partition orphans, build the segment trie,
      split project-and-prefix nodes, compact single-child folder chains, sort children,
      populate `descendantEncodedNames`, map nodes to display-only `Leaf` values.
- [x] run `swift test` — must pass before Task 2.

### Task 2: Core — tri-state derivation + folder cascade helpers

Files:

- Modify: `Sources/CCSyncCore/SelectionTree.swift`
- Modify: `Tests/CCSyncCoreTests/SelectionTreeTests.swift`

- [x] Write failing tests: all-selected → `.on`, none → `.off`, partial → `.mixed`;
      `setFolder(..., true/false)` flips exactly the selectable descendants and
      `resolvedSelection()` reflects it; `setFolder` never flips a non-selectable leaf;
      master-off inertness (folder set on, master off →
      `resolvedSelection().projectEncodedNames` empty); unknown encoded names:
      `folderState` ignores them when mixed with known ones and derives `.off` for an
      all-unknown list; `setFolder` with unknown names is a no-op for them and mutates
      nothing else.
- [x] Implement `FolderCheckState` and the `folderState`/`setFolder` extension helpers
      (routing writes through `setProject`; unknown names skipped).
- [x] run `swift test` — must pass before Task 3.

### Task 3: App — shared grouped renderer wired into both screens

Files:

- Create: `App/CCSync/ProjectSelectionTreeView.swift`
- Modify: `App/CCSync/BackupView.swift`, `App/CCSync/RestoreView.swift`

- [x] Add to both view models: `var projectTree: ProjectPathTree` (computed from the live
      `tree`), `func folderState(_:) -> FolderCheckState`, `func toggleFolder(_:_:)`
      (delegating to the tree; no-ops when `tree == nil`).
- [x] Build `ProjectSelectionTreeView`: recursive `DisclosureGroup` rows; folders
      default-expanded via a local `@State` expansion map keyed by row id, read as
      `map[id] ?? true` so row ids that appear later (e.g. after Refresh) also start
      expanded; folder header = tri-state checkbox image + label (tap: on→off,
      off/mixed→on via `toggleFolder`), disabled when `isRunning || !projectsMasterOn`;
      leaf rows keep today's rendering (middle-truncated path, `incompleteSummary`
      caption, greyed non-selectable, `disabled` by `isRunning`/master/`isSelectable`),
      with the checkbox bound via `projectBinding` — never a value read from the derived
      tree; and a trailing orphan section ("History only — no project entry") rendered
      with the same live leaf row (a `projectBinding`-bound toggle, not static text), so
      on the restore side orphans stay toggleable while on the backup side
      `isSelectable == false` keeps them greyed and disabled — exactly today's behaviour.
      Inputs are values + closures (`folderState`, `toggleFolder`, `projectBinding`) so
      both view models reuse it without a shared protocol.
- [x] Replace the flat project `ForEach` in `BackupView.selection` and
      `RestoreView.selection` with `ProjectSelectionTreeView`, keeping the "Global config"
      and "Projects" master toggles as-is.
- [x] run `swift test` (Core still green) and the `xcodebuild` gate — must pass before
      Task 4.

### Task 4: Verify acceptance criteria and gates

- [ ] run `swift test` — full suite green (existing + new Core tests).
- [ ] run the `xcodebuild -project App/CCSync.xcodeproj -scheme CCSync -configuration
      Debug CONFIGURATION_BUILD_DIR="$PWD/dist" build` gate — must pass.
- [ ] confirm acceptance 5/6 by inspection: default-checked tree `resolvedSelection()`
      unchanged; no CLI/archive/manifest code touched.
- [ ] manual walkthrough in the built app: folder collapse/expand, tri-state toggling,
      master-off greys out folders *and* leaves, orphan section renders after the tree
      (greyed on Backup, toggleable on Restore).

### Task 5: Update documentation

- [ ] CLAUDE.md: extend the core-contract section with `ProjectPathTree` (derivation-only,
      display fields without selection state, where it sits) and the
      `folderState`/`setFolder` helpers; note the documented
      grouping/compaction/prefix/ordering rules and the ignore-unknown-names rule.
- [ ] README.md: brief note on the grouped project tree and the "History only — no project
      entry" section (user-visible wording only).
