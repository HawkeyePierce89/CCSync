# CCSync

A native macOS tool for selective **backup and restore** of your personal Claude Code
configuration and session history between machines. It transfers your global config,
per-project settings, and session transcripts/history — automatically remapping the
`/Users/<name>` segment of paths so a backup made on one Mac restores cleanly on
another under a different username.

CCSync reads **only** from known paths under `~/.claude` and `~/.claude.json` and from
explicit project paths. It never scans the filesystem.

## What is transferred

- **Global config** — `~/.claude/settings.json`, optional `~/.claude/CLAUDE.md`, and any
  of the directories `commands/agents/skills/rules/output-styles/hooks` that exist, plus
  the global `mcpServers` block from `~/.claude.json`.
- **Per-project settings** — for each project listed under `projects` in `~/.claude.json`:
  its generic-JSON entry (`allowedTools`, `mcpServers`, `enabledMcpjsonServers`, …) and the
  project's `.claude/settings.local.json`.
- **Project history** — session transcripts `projects/<encoded>/*.jsonl` (including
  sub-agent `agent-<shortId>.jsonl` transcripts) and, keyed by session UUID, the linked
  `file-history/<uuid>/`, `session-env/<uuid>/`, and
  `todos/<sessionId>-agent-<agentId>.json`.

## What is excluded

Keychain credentials, `history.jsonl`, and local noise — `statsig`, `debug`,
`shell-snapshots`, `cache`, `paste-cache`, and similar. Anything already tracked in a
project's own git (its `.claude/settings.json`, `.mcp.json`, project `CLAUDE.md`) is not
part of the transfer either.

## History fidelity boundary (different usernames)

Remapping substitutes only the user segment of paths: `/Users/<from>/` → `/Users/<to>/`
in absolute paths and `-Users-<from>-` → `-Users-<to>-` in encoded `projects/` directory
names. It does **not** rewrite paths recorded *inside* session records — the `.jsonl`
transcript format is version-fragile and deliberately left unparsed, so fields like `cwd`
and `file-history` metadata keep their original `/Users/<from>/` values.

Consequences:

- **Same username** (the common case): a no-op — everything resumes with full fidelity.
- **Different username**: `/resume` picks the session up and it resumes, but undo /
  `file-history` may be incomplete because the paths embedded in records still point at the
  source user. This is an accepted boundary, not a bug.

## CLI usage

Requires the Swift 6.0 toolchain and macOS 13 or later (the package declares
`swift-tools-version:6.0` and `platforms: [.macOS(.v13)]`).

Build the CLI with SwiftPM:

```sh
swift build          # or: swift build -c release
```

The `ccsync` executable has three commands (plus `ccsync --help` / `-h` / `help`, which
prints usage).

```sh
# Back up this machine's config + history into a single archive.
# Default destination is the home directory; override with --out.
ccsync backup [--out <path>]        # prints the written archive path

# Print the archive's project list as machine-readable JSON: top-level
# `sourceUser`, optional `sourceClaudeVersion`, and `projects` (each with its
# path, per-project settings, and an incompleteness flag).
ccsync list --archive <path>

# Restore from an archive by explicit selection.
ccsync restore --archive <path> \
    [--global | --no-global] \        # include/exclude global config
    [--projects | --no-projects] \    # include/exclude all projects (master switch)
    [--project <path> ...]            # restrict to specific source project paths (repeatable)
```

Selection semantics:

- With no selection flags, everything in the archive is restored (global + all projects).
- `--no-projects` restores only the global config; `--no-global` restores only projects.
- One or more `--project <path>` restricts the run to exactly those source paths.
- A project whose target folder is missing on this machine is **skipped** (reported with a
  reason) — the rest still restore and the run completes successfully.
- Before overwriting anything, CCSync writes a snapshot of the current state under
  `~/.claude/.ccsync-backups/<timestamp>/`. Restore is idempotent.

`restore` prints a machine-readable JSON report (`globalRestored`, `restoredProjects`,
`skippedProjects` with reasons, `warnings`, `snapshotPath`).

## The macOS app

`App/CCSync.xcodeproj` is a thin SwiftUI GUI over `CCSyncCore` with two screens — Backup
and Restore — that render the Core selection tree and call the same contract the CLI uses.
It carries no business logic of its own.

See **[App/README-build.md](App/README-build.md)** for how to build, sign with a
Developer ID, and notarize the app for distribution between machines. App Sandbox is off
(the tool reads/writes known home paths and user-picked project folders); Hardened Runtime
is on for notarization.

## Development

The core is a testable Swift library. All logic is exercised without touching the real
disk via an injectable `FileSystem` abstraction (see [CLAUDE.md](CLAUDE.md)).

```sh
swift test
```
