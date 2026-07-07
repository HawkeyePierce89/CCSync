# CCSync — Backup & Restore of Claude Code Config and History Across Macs

## Overview

A native macOS tool for selective backup/restore of personal Claude Code config and history
between machines. The core is a testable Swift library (`CCSyncCore`) with a machine-readable
contract (list of projects from an archive + restore by explicit selection). On top of it: a
thin CLI executable (`ccsync`) for automatable e2e runs, and a separate Xcode target for the
SwiftUI app (built manually in Xcode). Data is read only from known paths under `~/.claude`
and `~/.claude.json` and from explicit project paths — the filesystem is not scanned.

## Context

- The repository is empty (LICENSE, README, .gitignore) — everything is created from scratch.
- Actual layout (verified on this machine):
  - Global: `~/.claude/settings.json`, optionally `~/.claude/CLAUDE.md` and the directories
    `commands/agents/skills/rules/output-styles/hooks` (some may be absent — here only
    `commands` and `skills` exist).
  - `~/.claude.json`: generic JSON, top-level `mcpServers` (global) + `projects` (keys are
    absolute project paths; per-project settings: `allowedTools`, `mcpServers`,
    `enabledMcpjsonServers`, etc. + metrics).
  - `projects/<encoded>/` — the project path is encoded by replacing non-alnum chars with `-`;
    inside are `<session-uuid>.jsonl` transcripts of main sessions and
    `agent-<shortId>.jsonl` transcripts of sub-agents (Task tool).
  - History linked by session UUID: `file-history/<uuid>/`, `session-env/<uuid>/`,
    `todos/<sessionId>-agent-<agentId>.json`.
  - Excluded: Keychain credentials, `history.jsonl`, `statsig/debug/shell-snapshots/cache/
    paste-cache` and other local noise; and anything already in the project's git
    (`.claude/settings.json`, `.mcp.json`, the project `CLAUDE.md`).
- Remapping: only the `/Users/<user>` segment differs. Remap is done via targeted string
  substitution, not by decoding the path (see "Decisions before start", item 2).
- History fidelity boundary. We deliberately do not parse session internals (the format is
  version-fragile). Inside `.jsonl` there are fields with absolute paths (`cwd`, etc.), and
  `file-history` metadata references paths of tracked files — these stay with the "old"
  `/Users/<from>/`. With a matching username (the main case) this is a no-op. With different
  usernames, `/resume` will pick the session up, but undo/`file-history` may behave
  incompletely. This is an accepted boundary (see acceptance #4).
- Architecture (decided): SPM workspace — `CCSyncCore` (library) + `ccsync` (thin CLI) +
  Xcode SwiftUI app; App Sandbox off, hardened runtime + Developer ID + notarization for
  distributing the binary.

## Decisions before start (make before coding)

These four items shape the design/tests, so they are locked before Task 1.

1. **The archive layer must not break the `FileSystem` abstraction.**
   The point of the `FileSystem` protocol is to run backup/restore on an `InMemoryFileSystem`
   without touching disk. So `ArchiveWriter`/`ArchiveReader` operate on bytes (`Data`), and all
   disk I/O goes through `FileSystem`: `Collector → in-memory model → ArchiveWriter → Data →
   FileSystem.write`. The container format is assembled/parsed in memory from byte streams
   (pure-Swift tar/zip over `Data`/`Compression`), with no shell-out to system `tar`. Then
   Collector, ArchiveWriter/Reader, and RestorePlan are all testable on `InMemoryFileSystem`.
   *Accepted fallback* (if a pure container proves too costly): a system archiver is allowed,
   but confined behind the `FileSystem` boundary via a real temp dir; in that case those
   specific archive tests are marked as real-FS integration and do not run on
   `InMemoryFileSystem` (Collector/RestorePlan stay in-memory). Record the choice explicitly in Task 3.

2. **Remap by substituting the user segment, not decode→re-encode.**
   The encoding rule for `projects/` names diverges across sources (docs: "non-alnum → `-`"; a
   "hash of the path" is also reported). To avoid depending on the algorithm: take the original
   encoded name from the archive and substitute only the user segment — `-Users-<from>-` →
   `-Users-<to>-`, and for `~/.claude.json` keys `/Users/<from>/` → `/Users/<to>/`. No need to
   know the full encoding algorithm.

3. **Paths inside session records are not remapped** — see "History fidelity boundary" in
   Context. The wording of acceptance #4 is limited to matching usernames (below).

4. **Version source for `VersionCheck`.**
   There is no formal session schema version; use the Claude Code app version as a proxy. The
   source version is written into the manifest at backup time; the target version is read at
   restore time via an explicit method (lock in Task 4: invoke `claude --version` or read a
   known version file). `VersionCheck` is a heuristic warning on mismatch; it does not block.

## Development Approach

- Testing approach: TDD (the spec is precise, the core is deterministic) — tests first for
  `CCSyncCore` and the CLI.
- Key design decision: filesystem access through an injectable `FileSystem` abstraction (a
  protocol) with a logging test implementation — this makes the "don't scan the disk"
  requirement verifiable (a test asserts the exact set of read paths) and allows running
  backup/restore on a fixture home without a real `~/.claude`.
- Journal-assert calibration: the test allows listing of known directories (the session list is
  read by listing `projects/<proj>/`), but catches recursive disk traversal outside the known
  roots and explicit project paths.
- All operations on `~/.claude.json` go through generic JSON (no strict model), to preserve
  unknown/future keys.
- The selection-tree build logic (toggles) lives in Core (a `SelectionTree` type / builder), not
  in the View — so it can be tested via `swift test`. The SwiftUI View stays dumb.
- Each task ends with a green `swift test` before the next one.
- The SwiftUI app is a thin layer over Core, built manually in Xcode (its build/visual check is
  in Post-Completion, not an automatable checkbox).

## Implementation Steps

### Task 1: SPM scaffold, known paths, user remapping

Files:
- Create: `Package.swift`
- Create: `Sources/CCSyncCore/FileSystem.swift` (protocol + real implementation over FileManager)
- Create: `Sources/CCSyncCore/KnownPaths.swift`
- Create: `Sources/CCSyncCore/UserRemap.swift`
- Create: `Tests/CCSyncCoreTests/UserRemapTests.swift`
- Create: `Tests/CCSyncCoreTests/Support/InMemoryFileSystem.swift` (logging test FS + fixture helpers)

- [x] Define the `FileSystem` protocol (read file, list dir, exists, write, read/write byte blobs `Data` for the archive layer, directories-as-explicit-requests) + a real implementation; the test implementation logs every access.
- [x] `KnownPaths`: all global paths under `~/.claude` and `~/.claude.json`, the exclusion set (`history.jsonl`, `statsig`, `debug`, `shell-snapshots`, `cache`, `paste-cache`, etc.); the home directory is injected.
- [x] `UserRemap`: targeted substitution of the user segment for absolute paths (`/Users/<from>/` → `/Users/<to>/`) and for encoded `projects/` directory names (`-Users-<from>-` → `-Users-<to>-`). No decode→re-encode.
- [x] `UserRemap` tests: absolute paths, `projects/` directory names, idempotence when usernames match (no-op), no false positives on paths where `Users` appears not as a prefix.
- [x] `swift test` — green before Task 2.

### Task 2: Collect backup data (no FS scanning)

Files:
- Create: `Sources/CCSyncCore/Model/BackupModel.swift` (GlobalConfig, ProjectEntry, SessionArtifacts — in-memory)
- Create: `Sources/CCSyncCore/BackupCollector.swift`
- Create: `Tests/CCSyncCoreTests/BackupCollectorTests.swift`

- [x] Collect global: `settings.json`, optional `CLAUDE.md` and the directories `commands/agents/skills/rules/output-styles/hooks` (skip missing ones), global `mcpServers` from `~/.claude.json`.
- [x] Project list: `projects` keys from `~/.claude.json`, matched with `projects/` directories; per-project entry (generic JSON) + the project's `.claude/settings.local.json` by direct path.
- [x] Project history: transcripts `projects/<proj>/*.jsonl` — including sub-agent `agent-<shortId>.jsonl`; extract the full set of session UUIDs (main + sub-agents) and pull in `file-history/<uuid>/`, `session-env/<uuid>/`, `todos/<sessionId>-agent-<agentId>.json`.
- [x] Handling list mismatch: an entry exists in `~/.claude.json` but the `projects/<encoded>/` directory does not (and vice versa) — don't fail; the project goes into the manifest with whatever is actually available, and the incompleteness is recorded in the project's metadata.
- [x] Fixture-home tests: the collected model contains what's needed and excludes credentials/noise; a dedicated test for sub-agent sessions and their artifacts; a dedicated test for the entry/directory mismatch; assert via the test FS journal — access only to known paths and project paths (no recursive traversal).
- [x] `swift test` — green before Task 3.

### Task 3: Archive format and backup writing (manifest + payload)

Files:
- Create: `Sources/CCSyncCore/Archive/Manifest.swift` (format version, source user, project list with settings, source Claude Code version)
- Create: `Sources/CCSyncCore/Archive/ArchiveWriter.swift`
- Create: `Sources/CCSyncCore/BackupService.swift` (public backup API)
- Create: `Tests/CCSyncCoreTests/BackupServiceTests.swift`

- [x] Lock the archive-layer decision in code: `ArchiveWriter` operates on `Data`, disk I/O only through `FileSystem`. The container is assembled in memory (no shell-out to system `tar`). If the fallback is accepted — mark the archive tests as real-FS integration. (Decision: pure in-memory container `CCSAR1` over `Data`; fallback NOT taken.)
- [x] Manifest: archive-format schema version, source username, project list (path + per-project settings + the incompleteness flag from Task 2), source Claude Code version (for the restore-time check).
- [x] `ArchiveWriter`: a single archive with the global config, the manifest, and each project's history.
- [x] `BackupService`: default destination is the home directory, optionally specified; collects via `BackupCollector` and writes the archive through `FileSystem`.
- [x] Tests: the archive contains global + manifest + history; no credentials/noise; unpacking back yields a consistent structure; the whole run on `InMemoryFileSystem` (or real-FS integration if the fallback was taken).
- [x] `swift test` — green before Task 4.

### Task 4: Reading the archive and the "project list" contract

Files:
- Create: `Sources/CCSyncCore/Archive/ArchiveReader.swift`
- Create: `Sources/CCSyncCore/Archive/VersionCheck.swift`
- Create: `Sources/CCSyncCore/RestorePlan.swift` (machine-readable project list from the archive + selection)
- Create: `Tests/CCSyncCoreTests/ArchiveReaderTests.swift`

- [x] `ArchiveReader`: read the manifest/payload from `Data`; a corrupt archive or invalid manifest → error (stop).
- [x] The "return the project list from the archive" contract: the list of projects with their paths/settings (+ incompleteness flag) for UI and CLI.
- [x] `VersionCheck`: compare the source Claude Code version (from the manifest) and the target version obtained via an explicit method — lock in the target-version source (`claude --version` or a known version file). A mismatch → warning, does not block. (Decision: target version via `CommandClaudeVersionProvider` invoking `claude --version`.)
- [x] Tests: a valid archive parses and returns the list; a corrupt archive/manifest throws an error; the version check returns a warning on mismatch and stays silent on match; behavior when the target version is missing/unreadable (a soft warning, no stop).
- [x] `swift test` — green before Task 5.

### Task 5: Restore engine (merge, remap, snapshot, skip, history merge)

Files:
- Create: `Sources/CCSyncCore/Snapshot.swift` (non-destructive snapshot before overwrite)
- Create: `Sources/CCSyncCore/JSONMerge.swift` (generic-JSON merge into `~/.claude.json`)
- Create: `Sources/CCSyncCore/SelectionTree.swift` (two-level selection model + default-selection builder)
- Create: `Sources/CCSyncCore/RestoreService.swift` (public API "perform restore by explicit selection")
- Create: `Sources/CCSyncCore/RestoreReport.swift` (report: restored / skipped+reason / warnings)
- Create: `Tests/CCSyncCoreTests/RestoreServiceTests.swift`
- Create: `Tests/CCSyncCoreTests/SelectionTreeTests.swift`

- [x] `SelectionTree` in Core: global config (on/off on its own) + a "Projects" master + an explicit set of selected projects; with the master off — only global; default — all projects checked. The tree build and mapping to `Selection` live in Core, not the View.
- [x] Snapshot of current state before any overwrite.
- [x] Snapshot policy: lock in the snapshot location (e.g. `~/.claude/.ccsync-backups/<timestamp>/`), the behavior on a mid-restore failure (leave the snapshot for manual recovery — no auto-rollback, to keep it simple; document explicitly), and the rule for cleaning up old snapshots (or its absence). (Decision: location `~/.claude/.ccsync-backups/<timestamp>/`; no auto-rollback on failure; no automatic cleanup — documented in `Snapshot.swift`.)
- [x] Global restore: `settings.json`, `CLAUDE.md`, directories; global `mcpServers` merged into `~/.claude.json` without wiping the rest.
- [x] Project restore: user remap in paths and `projects/` directory names (by substitution); if the target project folder at the remapped path is absent — skip (no entry, no history, no garbage), continue, mark it in the report with a reason.
- [x] Merge the per-project entry and `mcpServers` into `~/.claude.json` (preserve unknown/future keys); history — union by session UUID, including sub-agent sessions/artifacts (no collisions).
- [x] Version check (warning, no stop); idempotence of a repeated restore.
- [x] Tests: acceptance 2 (only the selected project / only global), 3 (different username → correct path, including `projects/` directories; internal paths in records remain un-remapped — recorded as expected), 5 (one missing project → partial success + warning), 6 (idempotence + snapshot presence), merge does not overwrite others' entries.
- [x] Dedicated history-layout test: after restore the transcripts sit under the remapped `projects/` directory AND the corresponding `file-history/`/`session-env/`/`todos/` by UUID are present (including sub-agents).
- [x] `swift test` — green before Task 6.

### Task 6: Thin CLI executable (headless e2e)

Files:
- Create: `Sources/ccsync/main.swift` (argument parsing, calls into Core)
- Modify: `Package.swift` (executable target `ccsync`)
- Create: `Tests/CCSyncCoreTests/CLIEndToEndTests.swift`

- [x] Commands: `backup [--out <path>]`, `list --archive <path>` (machine-readable JSON of the project list), `restore --archive <path>` with explicit selection (`--global/--no-global`, `--projects/--no-projects`, repeatable `--project <path>`).
- [x] CLI is a thin layer: all logic in Core, same result without a GUI.
- [x] e2e test: on a fixture home, run backup → list → restore round-trip, check the report and the final state (acceptance 7).
- [x] `swift test` — green before Task 7.

### Task 7: SwiftUI macOS app (thin layer over Core)

Files:
- Create: `App/CCSync.xcodeproj` (Xcode target, local SPM package `CCSyncCore` as a dependency)
- Create: `App/CCSync/CCSyncApp.swift`
- Create: `App/CCSync/BackupView.swift`
- Create: `App/CCSync/RestoreView.swift` (+ ViewModel)
- Create: `App/CCSync/CCSync.entitlements` (sandbox off), hardened runtime / Developer ID settings
- Create: `App/README-build.md` (how to build/sign/notarize)

- [x] Backup screen: choose the destination directory (default — home directory), run, show the result; file operations are async, the UI does not block.
- [x] Restore screen: a "Global config" toggle; a "Projects" master (off → nested toggles inactive); a toggle per project from the archive, all checked by default; run and show the report (including skipped ones).
- [x] Views are thin: they render the `SelectionTree` from Core and call the contract (`list`/`restore`), with no business logic and no selection-tree building in the UI.
- [x] Target configuration: App Sandbox off, hardened runtime, Developer ID; a note that notarization is only for distributing the binary.
- [x] Selection-logic tests live in Core (`SelectionTreeTests`, Task 5) and run via `swift test`; the app target keeps only the thin binding (ViewModel unit tests — optional, where applicable, but the main logic is already covered in Core).

### Task 8: Verify acceptance criteria

- [ ] `swift test` — the whole suite green.
- [ ] Run the CLI e2e round-trip and check against acceptance 1–7 (except the app visuals).
- [ ] Verify no access outside known paths: assert via the test FS journal with calibration — listing of known directories allowed, recursive traversal outside known roots/project paths fails.
- [ ] Verify that with different usernames the `projects/` directories are remapped, while internal paths in records are not (matching the accepted boundary).

### Task 9: Update documentation

- [ ] Update `README.md`: purpose, transfer/exclusion scope, CLI usage (backup/list/restore), building the app, and explicitly — the history fidelity boundary with different usernames.
- [ ] Create `CLAUDE.md`: workspace layout (Core/CLI/App), the "don't scan the FS" invariant, the injectable-`FileSystem` approach, the core contract, and the decisions from the "Decisions before start" section (archive layer via `Data`, remap by substitution, version as a proxy, history boundaries).

## Acceptance Criteria

1. A backup on machine A contains the global config, a manifest of projects with settings, and their history; no credentials or excluded local noise are in the archive; the filesystem is not scanned (access only to known paths and project paths).
2. Restoring only the selected project on machine B (including a freshly cloned one) does not change the global settings or other projects; and conversely — with the Projects master off, only the global config is applied.
3. A project with a different username lands at the correct local path automatically (including `projects/` directories).
4. Restoring the selected project transfers its history; after restore the project's sessions appear in `/resume` and resume correctly. With a matching username — full resume; with a different one — session resume subject to the accepted boundary on internal paths.
5. A restore with one on-disk-missing project restores all present ones, marks the missing one as skipped in the report, and completes successfully (no interruption).
6. A repeated restore is idempotent; a snapshot exists before overwriting.
7. The core runs without the GUI and produces the same result.

## Error Handling

- A corrupt archive, an invalid manifest, or lack of write permission stop the process.
- "Skip and warn" applies only to on-disk-missing projects.

## Out of Scope

Scheduled auto-sync, git integration, cross-platform support, App Store, transferring the global `history.jsonl`.

## Post-Completion (manual)

- Build the SwiftUI app in Xcode, sign with Developer ID + notarize for distributing the binary between machines.
- Manual smoke: backup on machine A, restore a selected project on machine B (including a fresh clone) — sessions appear in `/resume` and resume correctly (acceptance 4).
- Optional: warn if Claude Code is running during restore (concurrent writes to `~/.claude.json`) — either catch this in the app, or note it as a known limitation.
