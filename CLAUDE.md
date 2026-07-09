# CLAUDE.md — working in the CCSync repository

CCSync backs up and restores Claude Code config and history across Macs. This file is the
orientation for anyone (including Claude) making changes here: the workspace layout, the
invariants that must hold, and the decisions locked before implementation.

## Workspace layout

An SPM workspace at the repository root, plus a separate Xcode app target.

- **`CCSyncCore`** (`Sources/CCSyncCore/`) — the library. All behaviour lives here:
  `BackupCollector`, `BackupService`, `Archive/` (Manifest, ArchiveWriter, ArchiveReader,
  Container, VersionCheck), `ProjectInventory`, `BackupPlan`, `RestorePlan`,
  `RestoreService`, `Snapshot`, `JSONMerge`, `SelectionTree`, `RestoreReport`, `KnownPaths`,
  `UserRemap`, `ProjectPathEncoding`, `FileSystem`, and `Model/` (BackupModel, JSONValue).
  The CLI entry point (`CCSyncCLI`) also lives in Core as `CLI.swift`.
- **`ccsync`** (`Sources/ccsync/main.swift`) — a thin executable. It builds a real
  `Environment` (a `RealFileSystem`, the home dir, stdout/stderr sinks, a version provider)
  and forwards `CommandLine.arguments` to `CCSyncCLI.run`. No logic.
- **App** (`App/CCSync.xcodeproj`) — a thin SwiftUI GUI referencing the root package as a
  local SwiftPM dependency. Views bind to Core's `SelectionTree` and call the same
  contract. Build/sign/notarize instructions in `App/README-build.md`.

Tests live in `Tests/CCSyncCoreTests/`. `swift test` is the gate — it must be green before
moving on.

## Core invariants

1. **Never scan the filesystem.** Read only from the paths in `KnownPaths` (under
   `~/.claude` and `~/.claude.json`) and from the explicit project paths listed in
   `~/.claude.json`. No recursive traversal outside the known roots. This is enforced by
   tests: `InMemoryFileSystem` journals every access, and tests assert the exact set of
   read paths and that `listDirectory(home)` is never called.

2. **All disk I/O goes through the `FileSystem` protocol.** It exposes read/write for text
   and byte blobs (`Data`), directory listing, existence checks, and explicit directory
   creation. The real implementation wraps `FileManager`; the test implementation
   (`InMemoryFileSystem`) runs everything off-disk and logs access. This makes the
   "don't scan the disk" requirement verifiable and lets backup/restore run against a
   fixture home. Do not reach for `FileManager` / `Foundation` file APIs directly in Core.

3. **`~/.claude.json` is handled as generic JSON** (`JSONValue`), never a strict model, so
   unknown/future keys survive a round-trip. Restore *merges* into it (via `JSONMerge`)
   rather than overwriting — other projects' and the global settings' entries are preserved.

4. **Selection logic lives in Core, not the View.** `SelectionTree` builds the two-level
   selection (global on/off + a "Projects" master + per-project toggles, all projects
   checked by default) and maps it to a `Selection`. `SelectionTreeTests` covers it under
   `swift test`; the SwiftUI views stay dumb.

## Core contract

The machine-readable seam shared by CLI and GUI:

- **List:** `RestorePlan(archive:)` parses an archive and returns the project list —
  paths, per-project settings, and an incompleteness flag — serialized as JSON by
  `RestorePlan.serialized`. Used by `ccsync list` and the Restore screen.
- **Restore:** `RestoreService.restore(archive:selection:)` performs restore by an explicit
  `Selection` and returns a `RestoreReport` (restored / skipped+reason / warnings /
  snapshot path). Same call from CLI and GUI → same result (acceptance #7).
- **Backup selection:** `BackupPlan(fileSystem:paths:sourceUser:)` mirrors `RestorePlan` but
  is sourced from the local machine (via `ProjectInventory.list`, which never reads
  sessions), and feeds `SelectionTree(plan:)`. `BackupCollector.collect(selection:)` and
  `BackupService.backup(to:selection:)` accept a `Selection` — global off skips
  `collectGlobal`, unselected projects are cut before any read. `nil` is a backward-compat
  "select all" default that GUI and CLI never pass: both always resolve the tree to an
  explicit `Selection`. On the restore side, `globalRestored` is true only when the
  global layer was both selected (`selection.global`) and actually applied — settings.json
  or CLAUDE.md or at least one config-dir file written, or the mcpServers merge performed.
  An archive with an empty global layer (from `--no-global` or an empty home) writes
  nothing, so `globalRestored` stays `false` even when `selection.global == true`.
  Orphaned history directories (a `projects/<encoded>/` node with `path.isEmpty`, i.e. no
  entry in `~/.claude.json`) are marked non-selectable in the default backup tree
  (`isSelectable == false`, `isSelected == false`), so they are excluded from a default
  backup in both GUI and CLI. `SelectionTree.setProject` is a no-op for a non-selectable
  node (it cannot be turned on). The node still appears in `BackupPlan`'s listing — nothing
  is deleted or hidden. On the restore side behaviour is unchanged: `SelectionTree(plan:
  RestorePlan)` marks every node `isSelectable == true`, so an orphan project carried by an
  older archive stays selectable and restorable.
- **Grouped project tree (presentation only):** `ProjectPathTree(nodes:)`
  (`ProjectPathTree.swift`) derives a collapsible, path-grouped view of the flat
  `SelectionTree.Node` list for both GUI screens. It sits *between* the `SelectionTree` and
  the SwiftUI renderer and deliberately carries **no selection state** — `Leaf` holds only
  display fields (`path`, `encodedName`, `incomplete`, `incompleteReason`,
  `incompleteSummary` — same wording as `SelectionTree.Node` — and `isSelectable`), never
  `isSelected`, so a renderer cannot bind a checkbox to stale data. All selection
  reads/writes still go through the live `SelectionTree` via `projectBinding` (per leaf) and
  the tri-state folder helpers `folderState(descendantEncodedNames:) -> FolderCheckState`
  (`.on`/`.off`/`.mixed`) and `setFolder(descendantEncodedNames:_:)`, which routes every
  write through `setProject` (non-selectable leaves are never flipped, master-off still
  resolves empty). Documented derivation rules, all covered by tests: **grouping** — split
  each non-orphan `path` on `/` (drop leading empty); final segment is the project leaf,
  preceding segments are folders in a trie. **Compaction** — a folder that is not itself a
  project and has exactly one child folder merges its label with that child (joined by `/`),
  repeated; stops at a leaf child, a multi-child folder, or a folder that is a project; root
  folder labels are prefixed with `/` to read as absolute. **Project-is-also-a-prefix** — a
  trie node that is both a project and has descendants emits two sibling rows (the project
  leaf, then a same-named folder of its descendants), leaf sorting first. **Child
  ordering** — case-insensitive by label with a leaf-before-same-named-folder tiebreak.
  **Orphans** (`path.isEmpty`) go to `orphans`, rendered after the tree, never in the
  hierarchy. **Duplicate paths** — two projects that share the same non-empty `path` with
  distinct encoded names (only from a crafted/older archive; local backups are path-keyed
  and unique) each emit their own leaf row and both appear in the enclosing folder's
  `descendantEncodedNames`, so neither is silently hidden while `SelectionTree` still holds
  it selectable. **Ignore-unknown-names** — `folderState` skips encoded names not present in
  the tree (an all-unknown list derives `.off`) and `setFolder`/`setProject` no-op on them,
  since the derived name list may in theory lag the live tree. The archive format, CLI, and
  `resolvedSelection()` are untouched.

## Decisions locked before implementation

1. **Archive layer over `Data`, not the `FileSystem` abstraction.** `ArchiveWriter` /
   `ArchiveReader` operate on bytes; the container (`CCSAR1`) is assembled and parsed in
   memory — no shell-out to system `tar`. Disk I/O is only the final `FileSystem.write` of
   the archive bytes. The pure in-memory container was implemented; the system-archiver
   fallback was **not** taken, so Collector, archive read/write, and RestorePlan are all
   testable on `InMemoryFileSystem`.

2. **Remap by substituting the user segment — never decode→re-encode.** The `projects/`
   encoding rule is not depended upon. Take the original encoded name from the archive and
   substitute only the user segment: `-Users-<from>-` → `-Users-<to>-` for directory names,
   `/Users/<from>/` → `/Users/<to>/` for absolute paths and `~/.claude.json` keys.

3. **Paths inside session records are not remapped.** The `.jsonl` transcript format is
   version-fragile and left unparsed, so `cwd` and `file-history` metadata keep their
   source `/Users/<from>/` values. No-op with matching usernames; with different usernames
   `/resume` works but undo/`file-history` may be incomplete. Accepted boundary
   (acceptance #4) — see README "History fidelity boundary".

4. **Version as a proxy for schema.** There is no formal session schema version, so the
   Claude Code app version stands in. The source version is stamped into the manifest at
   backup; the target version is read at restore via `CommandClaudeVersionProvider`
   (invokes `claude --version`). `VersionCheck` emits an advisory warning on mismatch or
   when the target version is unreadable — it never blocks.

## Snapshot policy

Before any overwrite, restore snapshots current state to
`~/.claude/.ccsync-backups/<timestamp>/`. On a mid-restore failure the snapshot is left in
place for manual recovery — no auto-rollback (kept simple, documented in `Snapshot.swift`).
No automatic cleanup of old snapshots.

## Error handling

A corrupt archive, an invalid manifest, or a lack of write permission stop the process.
"Skip and warn" applies *only* to on-disk-missing projects during restore.
