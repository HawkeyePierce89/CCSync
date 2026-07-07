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
            guard !project.path.isEmpty else {
                report.skippedProjects.append(.init(
                    path: project.path,
                    encodedName: project.encodedName,
                    reason: "project has no path recorded in the archive"
                ))
                continue
            }
            let targetPath = remap.remapAbsolutePath(project.path)
            let targetEncoded = remap.remapEncodedProjectName(project.encodedName)
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
            // path is `global/dirs/<dirName>/<relativePath>`.
            let relative = String(path.dropFirst(ArchiveLayout.globalDirsPrefix.count))
            let target = KnownPaths.join(paths.claudeDir, relative)
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
        // Merge the per-project entry into ~/.claude.json under the remapped key,
        // preserving other projects and any unknown/future keys.
        if let settings = project.settings {
            var projects = claudeJSON["projects"]?.objectValue ?? [:]
            let base = projects[targetPath] ?? .object([:])
            projects[targetPath] = JSONMerge.merge(base, settings)
            claudeJSON = setKey("projects", .object(projects), in: claudeJSON)
            dirty = true
        }

        let prefix = ArchiveLayout.projectsPrefix + project.encodedName + "/"

        if let local = reader.payload(at: prefix + ArchiveLayout.projectLocalSettings) {
            let target = KnownPaths.join(KnownPaths.join(targetPath, ".claude"), "settings.local.json")
            try writeWithSnapshot(local, to: target, within: targetPath, snapshot: snapshot, captured: &captured)
        }

        // History: route each session payload to its target location by UUID.
        let sessionsPrefix = prefix + ArchiveLayout.sessionsComponent + "/"
        for path in reader.payloadPaths(withPrefix: sessionsPrefix) {
            guard let data = reader.payload(at: path) else { continue }
            // rest is `<sessionID>/<component>/<relativePath...>`.
            let rest = String(path.dropFirst(sessionsPrefix.count))
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
        if try snapshot.capture(path) { captured = true }
        try fs.writeData(data, to: path)
    }

    private func readClaudeJSON() throws -> JSONValue {
        guard fs.exists(paths.claudeJSON) else { return .object([:]) }
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
