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
}
