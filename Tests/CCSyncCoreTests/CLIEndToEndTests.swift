import XCTest
@testable import CCSyncCore

/// Headless end-to-end coverage for the `ccsync` CLI (Task 6): a backup → list →
/// restore round-trip driven entirely through `CCSyncCLI.run` on an in-memory
/// filesystem — proving the core produces the same result without a GUI
/// (acceptance #7).
final class CLIEndToEndTests: XCTestCase {

    private struct StubProvider: ClaudeVersionProvider {
        let version: String?
        func currentVersion() -> String? { version }
    }

    private struct RunResult {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    /// Run one CLI command against `fs`/`home`, capturing streams and exit code.
    private func run(
        _ args: [String],
        fs: InMemoryFileSystem,
        home: String,
        targetVersion: String? = nil
    ) -> RunResult {
        var out = ""
        var err = ""
        let env = CCSyncCLI.Environment(
            fileSystem: fs,
            home: home,
            stdout: { out += $0 + "\n" },
            stderr: { err += $0 + "\n" },
            versionProvider: targetVersion.map(StubProvider.init(version:)),
            sourceClaudeVersion: "1.2.3"
        )
        let code = CCSyncCLI.run(args, environment: env)
        return RunResult(code: code, stdout: out, stderr: err)
    }

    private let appEncoded = "-Users-alice-git-App"
    private let webEncoded = "-Users-alice-git-Web"

    /// A source machine (`alice`) with global config, two project entries with
    /// `mcpServers`, per-project local settings, and a session transcript each.
    private func seedSourceHome(_ fs: InMemoryFileSystem, home: String) {
        fs.seedFile("\(home)/.claude/settings.json", #"{"theme":"dark"}"#)
        fs.seedFile("\(home)/.claude/CLAUDE.md", "# Global rules")
        fs.seedFile("\(home)/.claude.json", """
        {"mcpServers":{"git":{"command":"git-mcp"}},\
        "projects":{\
        "/Users/alice/git/App":{"allowedTools":["Bash"]},\
        "/Users/alice/git/Web":{"allowedTools":["Read"]}}}
        """)
        fs.seedFile("/Users/alice/git/App/.claude/settings.local.json", #"{"local":true}"#)
        fs.seedFile("/Users/alice/git/Web/.claude/settings.local.json", #"{"local":false}"#)
        fs.seedFile("\(home)/.claude/projects/\(appEncoded)/11111111-1111-1111-1111-111111111111.jsonl", "app-session")
        fs.seedFile("\(home)/.claude/projects/\(webEncoded)/22222222-2222-2222-2222-222222222222.jsonl", "web-session")
    }

    /// Back up `sourceFs` and return the archive bytes.
    private func makeArchive(sourceFs: InMemoryFileSystem, home: String) throws -> (dest: String, bytes: Data) {
        let result = run(["backup", "--out", "\(home)/backup.ccsync"], fs: sourceFs, home: home)
        XCTAssertEqual(result.code, 0, result.stderr)
        let dest = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(dest, "\(home)/backup.ccsync")
        return (dest, try sourceFs.readData(dest))
    }

    /// Seed a fresh target machine (`alice`) with both project working folders and
    /// the archive file at `archivePath`.
    private func seedTargetHome(archive: Data, at archivePath: String) -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        fs.seedDirectory("/Users/alice/git/App")
        fs.seedDirectory("/Users/alice/git/Web")
        fs.seedFile(archivePath, archive)
        return fs
    }

    // MARK: - Round-trip (acceptance #7)

    func testBackupListRestoreRoundTrip() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem()
        seedSourceHome(sourceFs, home: home)

        let (_, bytes) = try makeArchive(sourceFs: sourceFs, home: home)

        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: bytes, at: archivePath)

        // list — machine-readable JSON project list from the archive.
        let listed = run(["list", "--archive", archivePath], fs: targetFs, home: home)
        XCTAssertEqual(listed.code, 0, listed.stderr)
        let listJSON = try JSONValue(data: Data(listed.stdout.utf8))
        XCTAssertEqual(listJSON["sourceUser"]?.stringValue, "alice")
        let listedPaths = Set((listJSON["projects"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue })
        XCTAssertEqual(listedPaths, ["/Users/alice/git/App", "/Users/alice/git/Web"])

        // restore — default selection: global + all projects.
        let restored = run(["restore", "--archive", archivePath], fs: targetFs, home: home, targetVersion: "1.2.3")
        XCTAssertEqual(restored.code, 0, restored.stderr)
        let report = try JSONValue(data: Data(restored.stdout.utf8))
        XCTAssertEqual(report["globalRestored"]?.boolValue, true)
        let restoredProjects = Set((report["restoredProjects"]?.arrayValue ?? []).compactMap(\.stringValue))
        XCTAssertEqual(restoredProjects, ["/Users/alice/git/App", "/Users/alice/git/Web"])
        XCTAssertEqual(report["skippedProjects"]?.arrayValue?.isEmpty, true)

        // Final state transferred to the target machine.
        XCTAssertEqual(try targetFs.readData("\(home)/.claude/settings.json"), Data(#"{"theme":"dark"}"#.utf8))
        XCTAssertEqual(try targetFs.readData("\(home)/.claude/CLAUDE.md"), Data("# Global rules".utf8))
        XCTAssertEqual(
            try targetFs.readData("\(home)/.claude/projects/\(appEncoded)/11111111-1111-1111-1111-111111111111.jsonl"),
            Data("app-session".utf8)
        )
        let claudeJSON = try JSONValue(data: targetFs.readData("\(home)/.claude.json"))
        XCTAssertEqual(claudeJSON["mcpServers"]?["git"]?["command"]?.stringValue, "git-mcp")
        XCTAssertNotNil(claudeJSON["projects"]?["/Users/alice/git/App"])
        XCTAssertNotNil(claudeJSON["projects"]?["/Users/alice/git/Web"])
    }

    // MARK: - Selection flags

    func testRestoreNoProjectsAppliesOnlyGlobal() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem()
        seedSourceHome(sourceFs, home: home)
        let (_, bytes) = try makeArchive(sourceFs: sourceFs, home: home)

        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: bytes, at: archivePath)

        let restored = run(["restore", "--archive", archivePath, "--no-projects"], fs: targetFs, home: home)
        XCTAssertEqual(restored.code, 0, restored.stderr)
        let report = try JSONValue(data: Data(restored.stdout.utf8))
        XCTAssertEqual(report["globalRestored"]?.boolValue, true)
        XCTAssertEqual(report["restoredProjects"]?.arrayValue?.isEmpty, true)
        // No project entry merged into ~/.claude.json.
        let claudeJSON = try JSONValue(data: targetFs.readData("\(home)/.claude.json"))
        XCTAssertNil(claudeJSON["projects"]?["/Users/alice/git/App"])
    }

    func testRestoreSpecificProjectOnly() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem()
        seedSourceHome(sourceFs, home: home)
        let (_, bytes) = try makeArchive(sourceFs: sourceFs, home: home)

        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: bytes, at: archivePath)

        let restored = run(
            ["restore", "--archive", archivePath, "--no-global", "--project", "/Users/alice/git/App"],
            fs: targetFs, home: home
        )
        XCTAssertEqual(restored.code, 0, restored.stderr)
        let report = try JSONValue(data: Data(restored.stdout.utf8))
        XCTAssertEqual(report["globalRestored"]?.boolValue, false)
        let restoredProjects = Set((report["restoredProjects"]?.arrayValue ?? []).compactMap(\.stringValue))
        XCTAssertEqual(restoredProjects, ["/Users/alice/git/App"])
        // Web transcript must NOT have been written.
        XCTAssertFalse(targetFs.exists("\(home)/.claude/projects/\(webEncoded)/22222222-2222-2222-2222-222222222222.jsonl"))
    }

    // MARK: - Backup selection flags

    /// Back up `sourceFs` with the given extra flags and return the archive bytes.
    private func makeArchive(
        sourceFs: InMemoryFileSystem,
        home: String,
        flags: [String]
    ) throws -> (result: RunResult, bytes: Data?) {
        let dest = "\(home)/backup.ccsync"
        let result = run(["backup", "--out", dest] + flags, fs: sourceFs, home: home)
        let bytes = sourceFs.exists(dest) ? try sourceFs.readData(dest) : nil
        return (result, bytes)
    }

    /// No flags must equal a full backup: global + both projects, identical to the
    /// explicit `--global --projects` selection.
    func testBackupNoFlagsEqualsFullBackup() throws {
        let home = "/Users/alice"
        let plain = InMemoryFileSystem(); seedSourceHome(plain, home: home)
        let explicit = InMemoryFileSystem(); seedSourceHome(explicit, home: home)

        let (r1, b1) = try makeArchive(sourceFs: plain, home: home, flags: [])
        let (r2, b2) = try makeArchive(sourceFs: explicit, home: home, flags: ["--global", "--projects"])
        XCTAssertEqual(r1.code, 0, r1.stderr)
        XCTAssertEqual(r2.code, 0, r2.stderr)
        XCTAssertEqual(b1, b2, "no flags must produce the same archive as --global --projects")

        // Both projects present in the archive.
        let plan = try RestorePlan(archive: XCTUnwrap(b1))
        XCTAssertEqual(Set(plan.projects.map(\.path)), ["/Users/alice/git/App", "/Users/alice/git/Web"])
    }

    /// `--project <path>` restricts the archive to exactly the named local project.
    func testBackupSpecificProjectOnly() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let (result, bytes) = try makeArchive(
            sourceFs: sourceFs, home: home, flags: ["--project", "/Users/alice/git/App"]
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let plan = try RestorePlan(archive: XCTUnwrap(bytes))
        XCTAssertEqual(plan.projects.map(\.path), ["/Users/alice/git/App"])

        // Round-trip: only App is restored, Web's transcript never written.
        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: try XCTUnwrap(bytes), at: archivePath)
        let restored = run(["restore", "--archive", archivePath], fs: targetFs, home: home)
        XCTAssertEqual(restored.code, 0, restored.stderr)
        XCTAssertTrue(targetFs.exists("\(home)/.claude/projects/\(appEncoded)/11111111-1111-1111-1111-111111111111.jsonl"))
        XCTAssertFalse(targetFs.exists("\(home)/.claude/projects/\(webEncoded)/22222222-2222-2222-2222-222222222222.jsonl"))
    }

    /// `--no-projects` drops every project from the archive but keeps the global
    /// layer, which restores onto the target.
    func testBackupNoProjectsKeepsOnlyGlobal() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let (result, bytes) = try makeArchive(sourceFs: sourceFs, home: home, flags: ["--no-projects"])
        XCTAssertEqual(result.code, 0, result.stderr)
        let plan = try RestorePlan(archive: XCTUnwrap(bytes))
        XCTAssertTrue(plan.projects.isEmpty, "no project should survive --no-projects")

        // Global layer is present: it restores on the target.
        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: try XCTUnwrap(bytes), at: archivePath)
        let restored = run(["restore", "--archive", archivePath], fs: targetFs, home: home)
        XCTAssertEqual(restored.code, 0, restored.stderr)
        XCTAssertEqual(try targetFs.readData("\(home)/.claude/settings.json"), Data(#"{"theme":"dark"}"#.utf8))
    }

    /// `--no-global` drops the global layer from the archive; restoring it writes
    /// no global files, but the projects still transfer.
    func testBackupNoGlobalKeepsOnlyProjects() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let (result, bytes) = try makeArchive(sourceFs: sourceFs, home: home, flags: ["--no-global"])
        XCTAssertEqual(result.code, 0, result.stderr)

        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: try XCTUnwrap(bytes), at: archivePath)
        let restored = run(["restore", "--archive", archivePath], fs: targetFs, home: home)
        XCTAssertEqual(restored.code, 0, restored.stderr)
        // No global files written — the archive carried an empty global layer.
        XCTAssertFalse(targetFs.exists("\(home)/.claude/settings.json"))
        XCTAssertFalse(targetFs.exists("\(home)/.claude/CLAUDE.md"))
        // Projects still transferred.
        XCTAssertTrue(targetFs.exists("\(home)/.claude/projects/\(appEncoded)/11111111-1111-1111-1111-111111111111.jsonl"))
    }

    /// Conflicting `--global --no-global`: "off" wins (evaluated last), matching the
    /// restore-side parser. The archive carries no global layer.
    func testBackupGlobalConflictOffWins() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let (result, bytes) = try makeArchive(
            sourceFs: sourceFs, home: home, flags: ["--global", "--no-global"]
        )
        XCTAssertEqual(result.code, 0, result.stderr)

        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: try XCTUnwrap(bytes), at: archivePath)
        let restored = run(["restore", "--archive", archivePath], fs: targetFs, home: home)
        XCTAssertEqual(restored.code, 0, restored.stderr)
        XCTAssertFalse(targetFs.exists("\(home)/.claude/settings.json"))
    }

    /// `--project` with a path that isn't on this machine warns and is skipped; with
    /// no other project enabled the archive ends up with no projects.
    func testBackupUnknownProjectPathWarnsAndSkips() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let (result, bytes) = try makeArchive(
            sourceFs: sourceFs, home: home, flags: ["--project", "/Users/alice/git/Nope"]
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("Nope"), result.stderr)
        let plan = try RestorePlan(archive: XCTUnwrap(bytes))
        XCTAssertTrue(plan.projects.isEmpty)
    }

    /// Parity with restore: a disabled master gates the whole set. `--no-projects
    /// --project <path>` yields no projects despite the `--project` — it is inert
    /// while the master is off — and is equivalent to plain `--no-projects`.
    func testBackupNoProjectsWithProjectIsInert() throws {
        let home = "/Users/alice"
        let gated = InMemoryFileSystem(); seedSourceHome(gated, home: home)
        let plain = InMemoryFileSystem(); seedSourceHome(plain, home: home)

        let (r1, b1) = try makeArchive(
            sourceFs: gated, home: home, flags: ["--no-projects", "--project", "/Users/alice/git/App"]
        )
        let (r2, b2) = try makeArchive(sourceFs: plain, home: home, flags: ["--no-projects"])
        XCTAssertEqual(r1.code, 0, r1.stderr)
        XCTAssertEqual(r2.code, 0, r2.stderr)
        XCTAssertEqual(b1, b2, "--project must be inert when the master is off")

        let plan = try RestorePlan(archive: XCTUnwrap(b1))
        XCTAssertTrue(plan.projects.isEmpty, "no project despite --project when the master is off")

        // The global layer is still present.
        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: try XCTUnwrap(b1), at: archivePath)
        let restored = run(["restore", "--archive", archivePath], fs: targetFs, home: home)
        XCTAssertEqual(restored.code, 0, restored.stderr)
        XCTAssertEqual(try targetFs.readData("\(home)/.claude/settings.json"), Data(#"{"theme":"dark"}"#.utf8))
    }

    /// A `--project` with no following value is a usage error, not a silent
    /// fall-back to "all projects" — and no archive is written.
    func testBackupDanglingProjectFlagIsUsageError() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let (result, bytes) = try makeArchive(sourceFs: sourceFs, home: home, flags: ["--project"])
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--project"), result.stderr)
        XCTAssertNil(bytes, "no archive should be written on a usage error")
    }

    /// `--project` immediately followed by another flag is a usage error, not a
    /// swallow of the flag as a path.
    func testBackupProjectFlagDoesNotSwallowNextFlag() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let (result, bytes) = try makeArchive(
            sourceFs: sourceFs, home: home, flags: ["--project", "--no-global"]
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--project"), result.stderr)
        XCTAssertNil(bytes, "no archive should be written on a usage error")
    }

    /// The same guard must hold when a real path trails the swallowed flag:
    /// `--project --no-global <path>` must not let `--no-global` be consumed first
    /// (breaking adjacency) so `--project` binds to the path and global is silently
    /// dropped. Left-to-right parsing over the original stream prevents exactly this.
    func testBackupProjectFlagDoesNotSwallowNextFlagWithTrailingPath() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let (result, bytes) = try makeArchive(
            sourceFs: sourceFs, home: home,
            flags: ["--project", "--no-global", "/Users/alice/git/App"]
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--project"), result.stderr)
        XCTAssertNil(bytes, "no archive should be written on a usage error")
    }

    /// A value option between `--project` and a trailing path must not be
    /// consumed first (shifting the path next to `--project`): `--project --out
    /// <path> <projectPath>` must be a usage error. The parser validates
    /// adjacency against the original token stream, left-to-right, so no
    /// out-of-order removal can misbind `--project` to the path.
    func testBackupProjectFlagDoesNotSwallowValueOption() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let result = run(
            ["backup", "--project", "--out", "\(home)/backup.ccsync", "/Users/alice/git/App"],
            fs: sourceFs, home: home
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--project"), result.stderr)
        XCTAssertFalse(sourceFs.exists("\(home)/backup.ccsync"),
                       "no archive should be written on a usage error")
    }

    /// `--out` immediately followed by another flag is a usage error, not a
    /// swallow of the flag as the output filename (which would still back up
    /// global config despite the user opting out).
    func testBackupOutFlagDoesNotSwallowNextFlag() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let result = run(["backup", "--out", "--no-global"], fs: sourceFs, home: home)
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--out"), result.stderr)
        XCTAssertFalse(sourceFs.allFiles.keys.contains("\(home)/--no-global"),
                       "no archive should be written under the swallowed flag name")
    }

    /// A singleton value option given twice is a usage error, not a silent
    /// last-wins: `restore --archive a --archive b` must not quietly restore `b`.
    func testRestoreDuplicateArchiveFlagIsUsageError() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem()
        seedSourceHome(sourceFs, home: home)
        let (_, bytes) = try makeArchive(sourceFs: sourceFs, home: home)
        let safe = "/tmp/safe.ccsync"
        let other = "/tmp/other.ccsync"
        let targetFs = seedTargetHome(archive: bytes, at: safe)
        try targetFs.writeData(bytes, to: other)

        // Parsing rejects the duplicate before any archive is read, so both
        // being valid archives makes the point: `other` is never restored.
        let result = run(["restore", "--archive", safe, "--archive", other],
                         fs: targetFs, home: home, targetVersion: "1.2.3")
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--archive"), result.stderr)
    }

    /// The backup side of the same rule for `--out`.
    func testBackupDuplicateOutFlagIsUsageError() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem(); seedSourceHome(sourceFs, home: home)

        let result = run(["backup", "--out", "\(home)/a.ccsync", "--out", "\(home)/b.ccsync"],
                         fs: sourceFs, home: home)
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--out"), result.stderr)
        XCTAssertFalse(sourceFs.allFiles.keys.contains("\(home)/b.ccsync"),
                       "no archive should be written when --out is duplicated")
    }

    // MARK: - Errors & usage

    func testListMissingArchiveArgumentFails() {
        let fs = InMemoryFileSystem()
        let result = run(["list"], fs: fs, home: "/Users/alice")
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--archive"), result.stderr)
    }

    func testMissingArchiveFileFails() {
        let fs = InMemoryFileSystem()
        let result = run(["list", "--archive", "/tmp/nope.ccsync"], fs: fs, home: "/Users/alice")
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.stderr.contains("not found"), result.stderr)
    }

    func testUnknownCommandFails() {
        let fs = InMemoryFileSystem()
        let result = run(["frobnicate"], fs: fs, home: "/Users/alice")
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("unknown command"), result.stderr)
    }

    /// A `--project` with no following value must be a usage error, not a silent
    /// fall-back to the default "all projects selected".
    func testRestoreDanglingProjectFlagIsUsageError() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem()
        seedSourceHome(sourceFs, home: home)
        let (_, bytes) = try makeArchive(sourceFs: sourceFs, home: home)

        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: bytes, at: archivePath)

        let result = run(
            ["restore", "--archive", archivePath, "--project"],
            fs: targetFs, home: home
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--project"), result.stderr)
        // Nothing was restored — the run stopped at argument parsing.
        XCTAssertFalse(targetFs.exists("\(home)/.claude/projects/\(appEncoded)/11111111-1111-1111-1111-111111111111.jsonl"))
    }

    /// `--project` immediately followed by another flag must be a usage error,
    /// not swallow the flag as a path. Otherwise `--project --no-global` would
    /// consume `--no-global`, leaving global config to be restored despite the
    /// user opting out.
    func testRestoreProjectFlagDoesNotSwallowNextFlag() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem()
        seedSourceHome(sourceFs, home: home)
        let (_, bytes) = try makeArchive(sourceFs: sourceFs, home: home)

        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: bytes, at: archivePath)

        let result = run(
            ["restore", "--archive", archivePath, "--project", "--no-global"],
            fs: targetFs, home: home
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--project"), result.stderr)
        // Global config was not restored — parsing stopped before any write.
        XCTAssertFalse(targetFs.exists("\(home)/.claude/settings.json"))
    }

    /// As above, but with a real path trailing the swallowed flag:
    /// `--project --no-global <path>` must still be a usage error — the boolean
    /// flag must not be removed ahead of the `--project` adjacency check.
    func testRestoreProjectFlagDoesNotSwallowNextFlagWithTrailingPath() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem()
        seedSourceHome(sourceFs, home: home)
        let (_, bytes) = try makeArchive(sourceFs: sourceFs, home: home)

        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: bytes, at: archivePath)

        let result = run(
            ["restore", "--archive", archivePath, "--project", "--no-global", "/Users/alice/git/App"],
            fs: targetFs, home: home
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--project"), result.stderr)
        XCTAssertFalse(targetFs.exists("\(home)/.claude/settings.json"))
    }

    /// The value-option variant on the restore side: `--project --archive <path>
    /// <projectPath>` must be a usage error, not let `--archive` be consumed
    /// first and bind `--project` to the trailing path.
    func testRestoreProjectFlagDoesNotSwallowValueOption() throws {
        let home = "/Users/alice"
        let sourceFs = InMemoryFileSystem()
        seedSourceHome(sourceFs, home: home)
        let (_, bytes) = try makeArchive(sourceFs: sourceFs, home: home)

        let archivePath = "/tmp/backup.ccsync"
        let targetFs = seedTargetHome(archive: bytes, at: archivePath)

        let result = run(
            ["restore", "--project", "--archive", archivePath, "/Users/alice/git/App"],
            fs: targetFs, home: home
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--project"), result.stderr)
        XCTAssertFalse(targetFs.exists("\(home)/.claude/settings.json"))
    }
}
