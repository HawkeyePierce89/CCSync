# CLAUDE.md — working in the CCSync repository

CCSync backs up and restores Claude Code config and history across Macs. This file is the
orientation for anyone (including Claude) making changes here: the workspace layout, the
invariants that must hold, and the decisions locked before implementation.

## Workspace layout

An SPM workspace at the repository root, plus a separate Xcode app target.

- **`CCSyncCore`** (`Sources/CCSyncCore/`) — the library. All behaviour lives here:
  `BackupCollector`, `BackupService`, `Archive/` (Manifest, ArchiveWriter, ArchiveReader,
  Container, VersionCheck), `RestorePlan`, `RestoreService`, `Snapshot`, `JSONMerge`,
  `SelectionTree`, `RestoreReport`, `KnownPaths`, `UserRemap`, `ProjectPathEncoding`,
  `FileSystem`, and `Model/` (BackupModel, JSONValue). The CLI entry point (`CCSyncCLI`)
  also lives in Core as `CLI.swift`.
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
