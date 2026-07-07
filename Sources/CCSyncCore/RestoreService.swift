import Foundation

/// Public restore API: apply a CCSync archive to this machine by an explicit
/// `Selection`. Everything runs through the injected `FileSystem`, so a full
/// restore is exercised on `InMemoryFileSystem`.
///
/// Behaviour (per the plan and acceptance criteria):
///   - Global layer: `settings.json`, `CLAUDE.md`, and config directories are
///     written back; the global `mcpServers` block is *merged* into
///     `~/.claude.json` without wiping the rest of the document.
///   - Projects: the source user segment is remapped in both the project path and
///     the `projects/` directory name by substitution (never decode→re-encode).
///     If the project folder is absent at the remapped path, the project is
///     skipped — no entry, no history, no garbage — recorded in the report, and
///     the run continues.
///   - Per-project entry and `mcpServers` are merged into `~/.claude.json`
///     (unknown/future keys and other projects survive). History is a union keyed
///     by session UUID / filename, so sub-agent sessions and existing sessions do
///     not collide.
///   - Paths *inside* session records are deliberately not remapped (the accepted
///     history-fidelity boundary).
///   - The version check is advisory only; a mismatch is a warning, never a stop.
///   - Every overwrite is preceded by a non-destructive `Snapshot`.
public struct RestoreService {
    private let fs: FileSystem
    private let paths: KnownPaths
    private let versionProvider: ClaudeVersionProvider?
    private let snapshotTimestamp: String?

    /// - Parameters:
    ///   - fileSystem: injected filesystem (real or in-memory).
    ///   - paths: known paths on the *target* machine (home determines the target
    ///     username used for remapping).
    ///   - versionProvider: optional provider for the target Claude Code version;
    ///     when supplied, a mismatch against the manifest yields a warning.
    ///   - snapshotTimestamp: fixed timestamp for the snapshot directory (defaults
    ///     to the current UTC time); injectable so tests are deterministic.
    public init(
        fileSystem: FileSystem,
        paths: KnownPaths,
        versionProvider: ClaudeVersionProvider? = nil,
        snapshotTimestamp: String? = nil
    ) {
        self.fs = fileSystem
        self.paths = paths
        self.versionProvider = versionProvider
        self.snapshotTimestamp = snapshotTimestamp
    }

    /// Apply `archive` according to `selection`, returning a report. Throws only on
    /// stop conditions (corrupt archive / invalid manifest, or a write failure);
    /// an on-disk-missing project is reported, not thrown.
    @discardableResult
    public func restore(archive data: Data, selection: Selection) throws -> RestoreReport {
        let reader = try ArchiveReader(data: data)
        let manifest = reader.manifest
        let targetUser = (paths.home as NSString).lastPathComponent
        let remap = UserRemap(from: manifest.sourceUser, to: targetUser)
        let snapshot = Snapshot(
            fileSystem: fs,
            home: paths.home,
            timestamp: snapshotTimestamp ?? Self.makeTimestamp()
        )

        var report = RestoreReport()
        var captured = false

        // Advisory version check — never blocks.
        if let versionProvider {
            let check = VersionCheck(manifest: manifest, provider: versionProvider)
            if let warning = check.warning { report.warnings.append(warning) }
        }

        // Load ~/.claude.json once; merges happen in memory and are written back once.
        var claudeJSON = try readClaudeJSON()
        var claudeJSONDirty = false

        if selection.global {
            try restoreGlobal(
                reader,
                snapshot: snapshot,
                captured: &captured,
                claudeJSON: &claudeJSON,
                dirty: &claudeJSONDirty
            )
            report.globalRestored = true
        }

        for project in manifest.projects
        where selection.projectEncodedNames.contains(project.encodedName) {
            // The encoded name feeds directly into `projects/`, `file-history/`,
            // etc. target paths — a `..` here would let a hostile archive escape
            // `~/.claude`. A legitimate encoded name is a single dot-free segment.
            guard !KnownPaths.hasTraversalComponent(project.encodedName) else {
                throw ArchiveError.corrupt("archive project name escapes its restore root: \(project.encodedName)")
            }
            let targetEncoded = remap.remapEncodedProjectName(project.encodedName)

            // Orphan history: a `projects/<encoded>/` directory with no
            // `~/.claude.json` entry (empty path). There is no project folder to
            // require and no settings to merge, but the session history is keyed
            // only by the encoded name, so restore it under the remapped encoded
            // directory rather than dropping it.
            guard !project.path.isEmpty else {
                try restoreProject(
                    project,
                    targetPath: "",
                    targetEncoded: targetEncoded,
                    reader: reader,
                    snapshot: snapshot,
                    captured: &captured,
                    claudeJSON: &claudeJSON,
                    dirty: &claudeJSONDirty
                )
                report.restoredProjects.append(paths.projectDir(encoded: targetEncoded))
                continue
            }
            let targetPath = remap.remapAbsolutePath(project.path)
            guard fs.isDirectory(targetPath) else {
                report.skippedProjects.append(.init(
                    path: targetPath,
                    encodedName: targetEncoded,
                    reason: "project folder is not present on this machine"
                ))
                continue
            }
            try restoreProject(
                project,
                targetPath: targetPath,
                targetEncoded: targetEncoded,
                reader: reader,
                snapshot: snapshot,
                captured: &captured,
                claudeJSON: &claudeJSON,
                dirty: &claudeJSONDirty
            )
            report.restoredProjects.append(targetPath)
        }

        if claudeJSONDirty {
            // Same no-follow guard as writeWithSnapshot: a symlinked
            // `~/.claude.json` on the target must not redirect this write.
            try rejectSymlinkedTarget(paths.claudeJSON, within: paths.home)
            if try snapshot.capture(paths.claudeJSON) { captured = true }
            try fs.writeData(try claudeJSON.serialized(pretty: true), to: paths.claudeJSON)
        }

        if captured { report.snapshotPath = snapshot.root }
        return report
    }

    // MARK: - Global

    private func restoreGlobal(
        _ reader: ArchiveReader,
        snapshot: Snapshot,
        captured: inout Bool,
        claudeJSON: inout JSONValue,
        dirty: inout Bool
    ) throws {
        if let settings = reader.payload(at: ArchiveLayout.globalSettings) {
            try writeWithSnapshot(settings, to: paths.globalSettings, within: paths.claudeDir, snapshot: snapshot, captured: &captured)
        }
        if let claudeMD = reader.payload(at: ArchiveLayout.globalClaudeMD) {
            try writeWithSnapshot(claudeMD, to: paths.globalClaudeMD, within: paths.claudeDir, snapshot: snapshot, captured: &captured)
        }
        for path in reader.payloadPaths(withPrefix: ArchiveLayout.globalDirsPrefix) {
            guard let data = reader.payload(at: path) else { continue }
            // path is `global/dirs/<dirName>/<relativePath>`. Constrain `<dirName>`
            // to the known global config dirs and require a real relative file
            // path beneath it, rejecting any `.`/`..` component. Without this a
            // hostile archive with no traversal component — e.g.
            // `global/dirs/.credentials.json`, `global/dirs/settings.json`, or
            // `global/dirs/projects/<encoded>/x.jsonl` — would still pass the
            // `~/.claude` containment check and overwrite excluded/unselected
            // areas. Write within the specific config-dir root.
            let relative = String(path.dropFirst(ArchiveLayout.globalDirsPrefix.count))
            let parts = relative.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty,
                  KnownPaths.globalConfigDirNames.contains(parts[0]),
                  !KnownPaths.hasTraversalComponent(relative) else {
                throw ArchiveError.corrupt("archive entry escapes its restore root: \(path)")
            }
            let dirRoot = KnownPaths.join(paths.claudeDir, parts[0])
            let target = KnownPaths.join(dirRoot, parts[1])
            // Contain and symlink-check from `~/.claude`, not `dirRoot`: the
            // symlink walk in `writeWithSnapshot` starts *below* its root, so a
            // `dirRoot` of `~/.claude/commands` would never test `commands`
            // itself. If that config dir is already a symlink on the target,
            // `RealFileSystem.writeData` would follow it outside `~/.claude`.
            // The allowlist above (`parts[0]` ∈ `globalConfigDirNames`) plus the
            // no-traversal check already pin the target under `~/.claude/<dir>`,
            // so containing against `claudeDir` is no looser — and it makes the
            // walk check the config-dir root component too.
            try writeWithSnapshot(data, to: target, within: paths.claudeDir, snapshot: snapshot, captured: &captured)
        }
        if let mcpData = reader.payload(at: ArchiveLayout.globalMCPServers),
           let mcp = try? JSONValue(data: mcpData) {
            let base = claudeJSON["mcpServers"] ?? .object([:])
            claudeJSON = setKey("mcpServers", JSONMerge.merge(base, mcp), in: claudeJSON)
            dirty = true
        }
    }

    // MARK: - Projects

    private func restoreProject(
        _ project: ManifestProject,
        targetPath: String,
        targetEncoded: String,
        reader: ArchiveReader,
        snapshot: Snapshot,
        captured: inout Bool,
        claudeJSON: inout JSONValue,
        dirty: inout Bool
    ) throws {
        // `~/.claude.json` and per-project `.claude/` settings live under the
        // project folder, so they only apply when we have a real target path.
        // Orphan history directories (empty path, no `~/.claude.json` entry)
        // carry no settings and skip this block; their session history below is
        // keyed by the encoded name and restores regardless.
        if !targetPath.isEmpty {
            // Merge the per-project entry into ~/.claude.json under the remapped
            // key, preserving other projects and any unknown/future keys.
            if let settings = project.settings {
                var projects = claudeJSON["projects"]?.objectValue ?? [:]
                let base = projects[targetPath] ?? .object([:])
                projects[targetPath] = JSONMerge.merge(base, settings)
                claudeJSON = setKey("projects", .object(projects), in: claudeJSON)
                dirty = true
            }

            if let local = reader.payload(at: ArchiveLayout.projectsPrefix + project.encodedName + "/" + ArchiveLayout.projectLocalSettings) {
                let target = KnownPaths.join(KnownPaths.join(targetPath, ".claude"), "settings.local.json")
                try writeWithSnapshot(local, to: target, within: targetPath, snapshot: snapshot, captured: &captured)
            }
        }

        let prefix = ArchiveLayout.projectsPrefix + project.encodedName + "/"

        // History: route each session payload to its target location by UUID.
        let sessionsPrefix = prefix + ArchiveLayout.sessionsComponent + "/"
        for path in reader.payloadPaths(withPrefix: sessionsPrefix) {
            guard let data = reader.payload(at: path) else { continue }
            // rest is `<sessionID>/<component>/<relativePath...>`. The session ID
            // and relative portion are attacker-influenced and feed into
            // `file-history/<id>/…`, `session-env/<id>/…`, etc.; reject any
            // `.`/`..` component so they cannot escape `~/.claude`.
            let rest = String(path.dropFirst(sessionsPrefix.count))
            guard !KnownPaths.hasTraversalComponent(rest) else {
                throw ArchiveError.corrupt("archive entry escapes its restore root: \(path)")
            }
            let components = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard components.count == 3 else { continue }
            let sessionID = components[0]
            let component = components[1]
            let relative = components[2]

            let target: String
            switch component {
            case ArchiveLayout.transcriptComponent:
                target = KnownPaths.join(paths.projectDir(encoded: targetEncoded), relative)
            case ArchiveLayout.fileHistoryComponent:
                target = KnownPaths.join(paths.fileHistoryDir(uuid: sessionID), relative)
            case ArchiveLayout.sessionEnvComponent:
                target = KnownPaths.join(paths.sessionEnvDir(uuid: sessionID), relative)
            case ArchiveLayout.todosComponent:
                target = KnownPaths.join(paths.todosDir, relative)
            default:
                continue
            }
            // All history targets live under `~/.claude`; a `..` in the encoded
            // name, session ID, or relative path must not escape it.
            try writeWithSnapshot(data, to: target, within: paths.claudeDir, snapshot: snapshot, captured: &captured)
        }
    }

    // MARK: - Helpers

    private func writeWithSnapshot(
        _ data: Data,
        to path: String,
        within root: String,
        snapshot: Snapshot,
        captured: inout Bool
    ) throws {
        // Archive entries carry attacker-influenced relative segments and encoded
        // project names. Reject any target that escapes its intended root via
        // `..` before touching disk — a hostile archive must not write outside
        // `~/.claude` (or the selected project folder). This is a stop condition,
        // like any other corruption.
        guard KnownPaths.isContained(path, within: root) else {
            throw ArchiveError.corrupt("archive entry escapes its restore root: \(path)")
        }
        try rejectSymlinkedTarget(path, within: root)
        if try snapshot.capture(path) { captured = true }
        try fs.writeData(data, to: path)
    }

    /// Reject a restore target that is itself a symlink, or that reaches its
    /// destination through a symlinked parent component beneath `root`.
    ///
    /// `KnownPaths.isContained` is purely lexical, and `FileSystem.writeData`
    /// (and the pre-write snapshot read) both follow symlinks. So a symlink
    /// already present on the *target* machine — e.g. `~/.claude/settings.json`
    /// or a `~/.claude/commands` directory pointed elsewhere — would let a
    /// write escape the intended restore root even though the path is lexically
    /// contained. Walk each component from just below `root` down to the target
    /// and stop, like any other corruption, if one is a symlink.
    private func rejectSymlinkedTarget(_ path: String, within root: String) throws {
        let normalizedRoot = KnownPaths.normalize(root)
        let normalizedPath = KnownPaths.normalize(path)
        guard normalizedPath == normalizedRoot
            || normalizedPath.hasPrefix(normalizedRoot + "/") else { return }

        var current = normalizedRoot
        let rest = normalizedPath.dropFirst(normalizedRoot.count)
        for segment in rest.split(separator: "/", omittingEmptySubsequences: true) {
            current = KnownPaths.join(current, String(segment))
            if fs.isSymlink(current) {
                throw ArchiveError.corrupt("restore target crosses a symlink: \(current)")
            }
        }
    }

    private func readClaudeJSON() throws -> JSONValue {
        // Don't read through a symlinked `~/.claude.json`. The write-back below
        // is refused for the same reason (`rejectSymlinkedTarget`); treat a
        // symlinked document as an empty base so the merge starts from scratch.
        guard fs.exists(paths.claudeJSON), !fs.isSymlink(paths.claudeJSON) else { return .object([:]) }
        return try JSONValue(data: fs.readData(paths.claudeJSON))
    }

    private func setKey(_ key: String, _ value: JSONValue, in json: JSONValue) -> JSONValue {
        var object = json.objectValue ?? [:]
        object[key] = value
        return .object(object)
    }

    private static func makeTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
