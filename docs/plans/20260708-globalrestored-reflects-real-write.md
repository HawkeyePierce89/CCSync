# globalRestored reflects a real write, not a mere selection

## Overview

Today `RestoreService.restore` sets `report.globalRestored = true` unconditionally
whenever `selection.global == true` (RestoreService.swift:86). For archives with an
empty global layer (captured via `ccsync backup --no-global` or from an empty home),
restore writes nothing, yet the report still says `globalRestored: true`. The fix:
`restoreGlobal` returns a `Bool` — "was the layer actually applied" — and that value
flows into the report. Only the truthfulness of one bool changes; the report format,
write order, snapshots, project skip-semantics, and error handling stay exactly as
they are.

## Context

- Files involved:
  - Modify: `Sources/CCSyncCore/RestoreService.swift` — `restoreGlobal` returns
    `Bool`; assignment of `report.globalRestored`.
  - Modify: `Tests/CCSyncCoreTests/BackupServiceTests.swift` — flip the stale assert
    in `testNoGlobalArchiveRestoresWithoutClobberingLiveGlobalConfig` (lines 262–264).
  - Modify: `Tests/CCSyncCoreTests/RestoreServiceTests.swift` — add two new tests
    (mcpServers-only → true; config-dir-only → true).
  - Modify: `CLAUDE.md` — line 67, update the `globalRestored` semantics.
  - Modify: `README.md` — around line 99, the restore JSON-report description.
- Related patterns:
  - `restoreGlobal` (RestoreService.swift:154–203) — four write paths: settings.json,
    CLAUDE.md, the config-dirs loop (global/dirs/...), and the mcpServers merge.
  - The mcpServers branch is double-gated:
    `if let mcpData = reader.payload(...), let mcp = try? JSONValue(data: mcpData)`
    (RestoreService.swift:197–202). A corrupt payload is silently dropped and `dirty`
    is never set — `applied` must follow the same gate.
  - The mcpServers merge only mutates the in-memory `claudeJSON`/`dirty`; the actual
    disk write to `~/.claude.json` happens once at the end of `restore()` under
    `if claudeJSONDirty` (RestoreService.swift:140–146). So the "mcpServers-only" test
    asserts the write via the journal, not inside `restoreGlobal`.
  - Journal assertion idiom: `fs.journal.contains(.writeData("\(home)/.claude.json"))`
    — already used at BackupServiceTests.swift:252.
  - Test fixtures build `GlobalConfig` (all fields optional, defaulting to nil/empty)
    via `BackupModel` + `ArchiveWriter().makeArchive` — RestoreServiceTests.swift:17–74.
  - Existing tests already covering "non-empty layer → true" that we do NOT touch:
    `RestoreServiceTests.testRestoreOnlyGlobalWithProjectsMasterOff` (142),
    `CLIEndToEndTests` (105, 137).
  - The empty-home path yields an empty `GlobalConfig()` and therefore an archive with
    no global payloads — identical in shape to `--no-global`. It is covered by
    `testNoGlobalArchiveRestoresWithoutClobberingLiveGlobalConfig`, not by a separate
    test.
- Dependencies: none external.

## Development Approach

- **Testing approach**: Regular (Core change first, then update/add tests within the
  same task) — the change is pointed and the behaviour is already covered by existing
  tests.
- The signature change and the stale-assert flip are one atomic behaviour change and
  live in a single task, so the gate after every task is a genuinely green
  `swift test`.
- **CRITICAL: every task includes new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Core — restoreGlobal returns whether it applied, and align the stale assert

**Files:**
- Modify: `Sources/CCSyncCore/RestoreService.swift`
- Modify: `Tests/CCSyncCoreTests/BackupServiceTests.swift`

- [x] Change `restoreGlobal`'s signature to `throws -> Bool`; introduce a local flag
  `applied = false`.
- [x] Set `applied = true` after writing settings.json, after writing CLAUDE.md, and
  inside the global/dirs loop after each successful `writeWithSnapshot`.
- [x] mcpServers branch: set `applied = true` ONLY inside the existing
  `if let mcpData ..., let mcp = try? JSONValue(data: mcpData)` block, on the same
  successful-parse path as `dirty = true` — right next to it. A corrupt/unparseable
  payload must not set `applied` (nothing was merged); this truthful skip is
  intentional, not an oversight.
- [x] Return `applied` at the end of the function.
- [x] In `restore(archive:selection:)` replace the unconditional
  `report.globalRestored = true` with an assignment of the `restoreGlobal(...)` call
  result. When `selection.global == false` behaviour is unchanged — the field stays
  `false` (RestoreReport default).
- [x] Confirm the write order, snapshots, and the claudeJSON/dirty/captured handling
  are unchanged — only the bool computation and return are edited.
- [x] In `testNoGlobalArchiveRestoresWithoutClobberingLiveGlobalConfig` replace
  `XCTAssertTrue(report.globalRestored)` with `XCTAssertFalse(report.globalRestored)`;
  remove the "the unchanged contract" comment and replace it with a short one
  explaining that an empty global layer writes nothing, so `globalRestored == false`
  even when `selection.global == true`.
- [x] `swift test` — green (the empty-layer archive now truthfully reports false;
  existing "non-empty layer → true" tests stay green).

### Task 2: Tests — non-empty layer yields true in boundary cases

**Files:**
- Modify: `Tests/CCSyncCoreTests/RestoreServiceTests.swift`

- [ ] Add an "mcpServers-only" test: archive with `GlobalConfig(mcpServers: .object(...))`
  and no settings/CLAUDE.md/configDirs; restore with `selection(global: true, projects: [])`
  → `XCTAssertTrue(report.globalRestored)`.
- [ ] In that test, assert the `~/.claude.json` write the way the code actually
  performs it: the merge only flips the in-memory `dirty` flag, and the single disk
  write happens at the end of `restore()`. So assert
  `XCTAssertTrue(fs.journal.contains(.writeData("\(home)/.claude.json")))` AND read the
  file back and assert the merged `mcpServers` content is present — do not assert
  anything "inside" `restoreGlobal`.
- [ ] Add a "config-dir-only" test: archive with
  `GlobalConfig(configDirs: [ConfigDir(name: "commands", files: [FileBlob(relativePath: "x.md", ...)])])`
  and no settings/CLAUDE.md/mcpServers; restore → `XCTAssertTrue(report.globalRestored)`;
  assert the file was written to `~/.claude/commands/x.md`.
- [ ] `swift test` — green.

### Task 3: Verify acceptance criteria

- [ ] Run the full `swift test` — all green.
- [ ] Confirm from code and tests: a non-empty global layer → `globalRestored: true`,
  including "mcpServers-only" and "config-dir-only" (Task 2); an empty global layer →
  `globalRestored: false` (Task 1's flipped assert in
  `testNoGlobalArchiveRestoresWithoutClobberingLiveGlobalConfig`).
- [ ] The empty-home path is not tested separately: an empty home produces an empty
  `GlobalConfig()` and thus an archive with no global payloads — the same shape
  `--no-global` produces — so its `globalRestored: false` follows from the absence of
  payloads and is covered by that same test. Confirm this equivalence by inspection,
  not by adding a test.
- [ ] Confirm the report format (set of fields) is unchanged.

### Task 4: Update documentation

- [ ] CLAUDE.md (line 67): remove "The restore side and globalRestored semantics are
  unchanged"; record the new semantics — `globalRestored` means the global layer was
  selected (`selection.global`) and actually applied (settings.json / CLAUDE.md / at
  least one config-dir file written, or the mcpServers merge performed).
- [ ] README.md (restore JSON-report description, ~line 99): clarify that
  `globalRestored: false` is possible even with --global when the archive had no global
  content.
