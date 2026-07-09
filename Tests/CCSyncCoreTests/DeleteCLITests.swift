import XCTest
@testable import CCSyncCore

/// Headless end-to-end coverage for the `ccsync delete` CLI (Task 5): the command
/// wires `ManagePlan` → `SelectionTree(managePlan:)` → `DeleteService` and prints a
/// `DeleteReport` as JSON, dry-run by default. Everything runs on an
/// `InMemoryFileSystem`, proving the CLI produces the same result the GUI does
/// (acceptance #5/#7).
final class DeleteCLITests: XCTestCase {

    private let home = "/Users/alice"
    private var paths: KnownPaths { KnownPaths(home: home) }

    private let appEncoded = "-Users-alice-git-App"
    private let libEncoded = "-Users-alice-git-Lib"
    private let appPath = "/Users/alice/git/App"
    private let libPath = "/Users/alice/git/Lib"
    private let appUUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let libUUID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private struct RunResult {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    private func run(_ args: [String], fs: InMemoryFileSystem) -> RunResult {
        var out = ""
        var err = ""
        let env = CCSyncCLI.Environment(
            fileSystem: fs,
            home: home,
            stdout: { out += $0 + "\n" },
            stderr: { err += $0 + "\n" }
        )
        let code = CCSyncCLI.run(args, environment: env)
        return RunResult(code: code, stdout: out, stderr: err)
    }

    // MARK: - Fixtures

    /// Two normal projects, each with a session + linked artifacts and a real
    /// on-disk project folder, plus an unknown top-level `mcpServers` key.
    private func twoProjects() -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude.json", """
        {"projects":{"\(appPath)":{"a":1},"\(libPath)":{"b":2}},"mcpServers":{"git":{}}}
        """)

        let appDir = "\(home)/.claude/projects/\(appEncoded)"
        fs.seedFile("\(appDir)/\(appUUID).jsonl", "app-main")
        fs.seedFile("\(home)/.claude/file-history/\(appUUID)/edit.json", "fh")
        fs.seedFile("\(home)/.claude/session-env/\(appUUID)/env.json", "env")
        fs.seedFile("\(home)/.claude/todos/\(appUUID).json", "todo")

        let libDir = "\(home)/.claude/projects/\(libEncoded)"
        fs.seedFile("\(libDir)/\(libUUID).jsonl", "lib-main")
        fs.seedFile("\(home)/.claude/file-history/\(libUUID)/edit.json", "lib-fh")

        fs.seedDirectory(appPath)
        fs.seedDirectory(libPath)
        return fs
    }

    private func appDataPaths() -> [String] {
        [
            paths.projectDir(encoded: appEncoded),
            paths.fileHistoryDir(uuid: appUUID),
            paths.sessionEnvDir(uuid: appUUID),
            KnownPaths.join(paths.todosDir, "\(appUUID).json"),
        ]
    }

    private func removedPaths(from stdout: String) throws -> [Set<String>] {
        let doc = try JSONValue(data: Data(stdout.utf8))
        let deleted = try XCTUnwrap(doc["deletedProjects"]?.arrayValue)
        return try deleted.map { project in
            let paths = try XCTUnwrap(project["removedPaths"]?.arrayValue)
            return Set(paths.compactMap(\.stringValue))
        }
    }

    // MARK: - Dry-run is the default

    func testDataOnlyDryRunChangesNothingButPrintsReport() throws {
        let fs = twoProjects()
        let result = run(["delete", "--project", appPath], fs: fs)

        XCTAssertEqual(result.code, 0, result.stderr)

        // Nothing removed on disk; the JSON key survives.
        XCTAssertFalse(fs.journal.contains { if case .removeItem = $0 { return true }; return false })
        XCTAssertTrue(fs.exists(paths.projectDir(encoded: appEncoded)))
        let doc = try JSONValue(data: fs.readData(paths.claudeJSON))
        XCTAssertNotNil(doc["projects"]?.objectValue?[appPath])

        // The would-be report is printed and flagged as a dry run.
        let printed = try JSONValue(data: Data(result.stdout.utf8))
        XCTAssertEqual(printed["dryRun"], .bool(true))
        XCTAssertEqual(try removedPaths(from: result.stdout), [Set(appDataPaths())])
        XCTAssertTrue(result.stderr.contains("dry run"))
        XCTAssertTrue(result.stderr.contains("--yes"))
    }

    // MARK: - --yes applies the deletion

    func testDataOnlyYesRemovesDataAndKey() throws {
        let fs = twoProjects()
        let result = run(["delete", "--project", appPath, "--yes"], fs: fs)

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(try removedPaths(from: result.stdout), [Set(appDataPaths())])

        // App's data gone, folder untouched, Lib intact.
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: appEncoded)))
        XCTAssertTrue(fs.isDirectory(appPath))
        XCTAssertTrue(fs.exists(paths.projectDir(encoded: libEncoded)))

        let doc = try JSONValue(data: fs.readData(paths.claudeJSON))
        let projects = try XCTUnwrap(doc["projects"]?.objectValue)
        XCTAssertNil(projects[appPath])
        XCTAssertEqual(projects[libPath], .object(["b": .int(2)]))
        XCTAssertEqual(doc["mcpServers"], .object(["git": .object([:])]))

        let printed = try JSONValue(data: Data(result.stdout.utf8))
        XCTAssertEqual(printed["dryRun"], .bool(false))
        XCTAssertFalse(fs.journal.contains(.listDirectory(home)))
    }

    // MARK: - --with-project-folder removes the folder too

    func testEntirelyYesRemovesFolder() throws {
        let fs = twoProjects()
        let result = run(
            ["delete", "--project", appPath, "--with-project-folder", "--yes"], fs: fs
        )

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(try removedPaths(from: result.stdout), [Set(appDataPaths() + [appPath])])
        XCTAssertFalse(fs.exists(appPath))
        XCTAssertTrue(fs.isDirectory(libPath))

        let printed = try JSONValue(data: Data(result.stdout.utf8))
        let deleted = try XCTUnwrap(printed["deletedProjects"]?.arrayValue?.first)
        XCTAssertEqual(deleted["folderRemoved"], .bool(true))
    }

    // MARK: - --orphans deletes orphan history dirs

    func testOrphansYesDeletesOrphanHistory() throws {
        let orphanEnc = "-Users-alice-git-Orphan"
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude.json", """
        {"projects":{"\(appPath)":{"a":1}}}
        """)
        fs.seedDirectory(appPath)
        fs.seedFile("\(home)/.claude/projects/\(appEncoded)/\(appUUID).jsonl", "app")
        // Orphan: a history dir with no ~/.claude.json entry.
        fs.seedFile("\(home)/.claude/projects/\(orphanEnc)/s.jsonl", "orphan")

        let result = run(["delete", "--orphans", "--yes"], fs: fs)

        XCTAssertEqual(result.code, 0, result.stderr)
        // The orphan history dir is gone; the real project's data is untouched.
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: orphanEnc)))
        XCTAssertTrue(fs.exists(paths.projectDir(encoded: appEncoded)))

        let printed = try JSONValue(data: Data(result.stdout.utf8))
        let deleted = try XCTUnwrap(printed["deletedProjects"]?.arrayValue)
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?["encodedName"], .string(orphanEnc))
        XCTAssertEqual(deleted.first?["path"], .string(""))
    }

    // MARK: - Folder-guard warnings reach stderr and the JSON report

    func testEntirelySymlinkFolderWarningReachesStderrAndJSON() throws {
        let linked = "/Users/alice/git/Linked"
        let encoded = ProjectPathEncoding.encode(linked)
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"\#(linked)":{}}}"#)
        fs.seedFile("\(home)/.claude/projects/\(encoded)/s.jsonl", "x")
        fs.seedSymlink(linked)

        let result = run(
            ["delete", "--project", linked, "--with-project-folder", "--yes"], fs: fs
        )

        XCTAssertEqual(result.code, 0, result.stderr)
        let warning = "project path is a symlink — folder not removed, Claude data removed"

        // The verbatim guard warning is emitted on stderr with the CLI prefix.
        XCTAssertTrue(result.stderr.contains("ccsync: warning: \(warning)"))

        // …and appears in the printed JSON report's warnings array.
        let printed = try JSONValue(data: Data(result.stdout.utf8))
        XCTAssertEqual(printed["warnings"]?.arrayValue, [.string(warning)])
        let deleted = try XCTUnwrap(printed["deletedProjects"]?.arrayValue?.first)
        XCTAssertEqual(deleted["folderRemoved"], .bool(false))
    }

    // MARK: - No selector is a usage error

    func testNoSelectorIsUsageError() throws {
        let fs = twoProjects()
        let result = run(["delete"], fs: fs)
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("requires"))
        // Nothing was touched.
        XCTAssertFalse(fs.journal.contains { if case .removeItem = $0 { return true }; return false })
    }

    // MARK: - Unknown --project path warns but still runs

    func testUnknownProjectPathWarns() throws {
        let fs = twoProjects()
        let result = run(["delete", "--project", "/Users/alice/git/Nope", "--yes"], fs: fs)
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("no project with path"))
        // No matching project selected → nothing removed.
        XCTAssertFalse(fs.journal.contains { if case .removeItem = $0 { return true }; return false })
    }

    // MARK: - Parity with a direct DeleteService run

    func testYesCLIReportEqualsDirectServiceRun() throws {
        // CLI path.
        let fsCLI = twoProjects()
        let cli = run(["delete", "--project", appPath, "--with-project-folder", "--yes"], fs: fsCLI)
        XCTAssertEqual(cli.code, 0, cli.stderr)

        // Direct service path on an identical fixture.
        let fsDirect = twoProjects()
        let selection = Selection(global: false, projectEncodedNames: [appEncoded])
        let report = try DeleteService(fileSystem: fsDirect, paths: paths).delete(
            selection: selection, operation: .entireProject, dryRun: false
        )

        // Same removed-path set from both routes.
        let cliRemoved = try removedPaths(from: cli.stdout).first
        XCTAssertEqual(cliRemoved, Set(report.deletedProjects.first?.removedPaths ?? []))

        // The CLI JSON reflects the same report fields.
        let printed = try JSONValue(data: Data(cli.stdout.utf8))
        let deleted = try XCTUnwrap(printed["deletedProjects"]?.arrayValue?.first)
        XCTAssertEqual(deleted["encodedName"], .string(report.deletedProjects.first!.encodedName))
        XCTAssertEqual(deleted["folderRemoved"], .bool(report.deletedProjects.first!.folderRemoved))
        XCTAssertEqual(printed["dryRun"], .bool(false))
    }
}
