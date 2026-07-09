import XCTest
@testable import CCSyncCore

final class DeleteServiceTests: XCTestCase {

    private let home = "/Users/alice"
    private var paths: KnownPaths { KnownPaths(home: home) }

    private let appEncoded = "-Users-alice-git-App"
    private let libEncoded = "-Users-alice-git-Lib"
    private let appPath = "/Users/alice/git/App"
    private let libPath = "/Users/alice/git/Lib"
    private let appUUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let libUUID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private func service(_ fs: InMemoryFileSystem) -> DeleteService {
        DeleteService(fileSystem: fs, paths: paths)
    }

    private func select(_ names: String...) -> Selection {
        Selection(global: false, projectEncodedNames: Set(names))
    }

    // MARK: - Fixtures

    /// Two normal projects, each with a session + linked artifacts and a real
    /// on-disk project folder, plus an unknown top-level `mcpServers` key that must
    /// survive any key removal.
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

        // On-disk project folders (the "Delete project entirely" targets).
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

    // MARK: - Claude-data-only

    func testDataOnlyRemovesHistoryArtifactsAndOneKey() throws {
        let fs = twoProjects()

        let report = try service(fs).delete(
            selection: select(appEncoded), operation: .claudeDataOnly, dryRun: false
        )

        // One deleted project, folder untouched, the exact data-path set targeted.
        XCTAssertEqual(report.deletedProjects.count, 1)
        let deleted = try XCTUnwrap(report.deletedProjects.first)
        XCTAssertEqual(deleted.encodedName, appEncoded)
        XCTAssertEqual(deleted.path, appPath)
        XCTAssertFalse(deleted.folderRemoved)
        XCTAssertEqual(Set(deleted.removedPaths), Set(appDataPaths()))
        XCTAssertTrue(report.skippedProjects.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)

        // App's Claude data is gone; Lib's is intact.
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: appEncoded)))
        XCTAssertFalse(fs.exists(paths.fileHistoryDir(uuid: appUUID)))
        XCTAssertTrue(fs.exists(paths.projectDir(encoded: libEncoded)))
        XCTAssertTrue(fs.exists(paths.fileHistoryDir(uuid: libUUID)))

        // The project folder on disk is untouched under data-only.
        XCTAssertTrue(fs.isDirectory(appPath))

        // Exactly one JSON key removed; sibling project + unknown key survive.
        let doc = try JSONValue(data: fs.readData(paths.claudeJSON))
        let projects = try XCTUnwrap(doc["projects"]?.objectValue)
        XCTAssertNil(projects[appPath])
        XCTAssertEqual(projects[libPath], .object(["b": .int(2)]))
        XCTAssertEqual(doc["mcpServers"], .object(["git": .object([:])]))

        // Invariant #1: home is never listed.
        XCTAssertFalse(fs.journal.contains(.listDirectory(home)))
    }

    // MARK: - Entire project

    func testEntirelyAdditionallyRemovesFolder() throws {
        let fs = twoProjects()

        let report = try service(fs).delete(
            selection: select(appEncoded), operation: .entireProject, dryRun: false
        )

        let deleted = try XCTUnwrap(report.deletedProjects.first)
        XCTAssertTrue(deleted.folderRemoved)
        XCTAssertTrue(deleted.removedPaths.contains(appPath))
        XCTAssertEqual(Set(deleted.removedPaths), Set(appDataPaths() + [appPath]))
        XCTAssertTrue(report.warnings.isEmpty)

        // The folder on disk is gone; the sibling's folder remains.
        XCTAssertFalse(fs.exists(appPath))
        XCTAssertTrue(fs.isDirectory(libPath))
    }

    // MARK: - Folder guards (verbatim warnings, data still cleaned)

    /// A fixture with one project whose folder trips each guard. The Claude data
    /// (history dir + key) is always present so the data cleanup proceeds.
    private func guardFixture(path: String, encoded: String, seedFolder: (InMemoryFileSystem) -> Void) -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"\#(path)":{}}}"#)
        fs.seedFile("\(home)/.claude/projects/\(encoded)/s.jsonl", "x")
        seedFolder(fs)
        return fs
    }

    func testEntirelyMissingFolderWarnsAndCleansData() throws {
        let path = "/Users/alice/git/Missing"
        let encoded = ProjectPathEncoding.encode(path)
        let fs = guardFixture(path: path, encoded: encoded) { _ in } // folder absent

        let report = try service(fs).delete(
            selection: select(encoded), operation: .entireProject, dryRun: false
        )

        let deleted = try XCTUnwrap(report.deletedProjects.first)
        XCTAssertFalse(deleted.folderRemoved)
        XCTAssertEqual(report.warnings, [
            "project folder not found on disk — Claude data removed, nothing to delete for the folder"
        ])
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: encoded)))
    }

    func testEntirelyUnsafePathWarnsAndCleansData() throws {
        // The project path *is* the home directory → unsafe.
        let encoded = ProjectPathEncoding.encode(home)
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"\#(home)":{}}}"#)
        fs.seedFile("\(home)/.claude/projects/\(encoded)/s.jsonl", "x")
        // home already exists as a directory.

        let report = try service(fs).delete(
            selection: select(encoded), operation: .entireProject, dryRun: false
        )

        let deleted = try XCTUnwrap(report.deletedProjects.first)
        XCTAssertFalse(deleted.folderRemoved)
        XCTAssertEqual(report.warnings, [
            "refused to delete project folder (unsafe path: \(home)) — Claude data removed"
        ])
        // Home is untouched; the Claude data was still cleaned.
        XCTAssertTrue(fs.isDirectory(home))
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: encoded)))
    }

    func testEntirelySymlinkWarnsAndNeverTouchesTarget() throws {
        let path = "/Users/alice/git/Linked"
        let encoded = ProjectPathEncoding.encode(path)
        let fs = guardFixture(path: path, encoded: encoded) { $0.seedSymlink(path) }

        let report = try service(fs).delete(
            selection: select(encoded), operation: .entireProject, dryRun: false
        )

        let deleted = try XCTUnwrap(report.deletedProjects.first)
        XCTAssertFalse(deleted.folderRemoved)
        XCTAssertEqual(report.warnings, [
            "project path is a symlink — folder not removed, Claude data removed"
        ])
        // The symlink entry itself is never removed (target never touched).
        XCTAssertFalse(fs.journal.contains(.removeItem(path)))
        XCTAssertFalse(fs.journal.contains(.removeItem(KnownPaths.normalize(path))))
    }

    func testEntirelyOrphanDegeneratesSilently() throws {
        // An orphan history dir with no ~/.claude.json entry (empty path).
        let orphanEnc = "-Users-alice-git-Orphan"
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude.json", #"{"projects":{}}"#)
        fs.seedFile("\(home)/.claude/projects/\(orphanEnc)/s.jsonl", "x")

        let report = try service(fs).delete(
            selection: select(orphanEnc), operation: .entireProject, dryRun: false
        )

        let deleted = try XCTUnwrap(report.deletedProjects.first)
        XCTAssertEqual(deleted.path, "")
        XCTAssertFalse(deleted.folderRemoved)
        XCTAssertEqual(deleted.removedPaths, [paths.projectDir(encoded: orphanEnc)])
        // No error, no warning — degenerated to data-only.
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertTrue(report.skippedProjects.isEmpty)
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: orphanEnc)))
    }

    // MARK: - Dry-run parity

    func testDryRunMutatesNothingButMatchesRealReport() throws {
        let fsDry = twoProjects()
        let dryReport = try service(fsDry).delete(
            selection: select(appEncoded), operation: .entireProject, dryRun: true
        )

        // No side effects at all.
        XCTAssertFalse(fsDry.journal.contains { if case .removeItem = $0 { return true }; return false })
        XCTAssertFalse(fsDry.journal.contains { if case .writeData = $0 { return true }; return false })
        XCTAssertTrue(fsDry.exists(paths.projectDir(encoded: appEncoded)))
        XCTAssertTrue(fsDry.isDirectory(appPath))
        let doc = try JSONValue(data: fsDry.readData(paths.claudeJSON))
        XCTAssertNotNil(doc["projects"]?.objectValue?[appPath])

        // The would-be report equals the real report (only `dryRun` differs).
        let fsReal = twoProjects()
        let realReport = try service(fsReal).delete(
            selection: select(appEncoded), operation: .entireProject, dryRun: false
        )
        var normalized = dryReport
        normalized.dryRun = realReport.dryRun
        XCTAssertEqual(normalized, realReport)
        XCTAssertTrue(dryReport.dryRun)
        XCTAssertFalse(realReport.dryRun)
    }

    // MARK: - Failure is a stop condition

    func testRemoveFailureThrowsDeleteError() throws {
        struct Boom: Error {}
        let fs = twoProjects()
        // Force the history-dir removal to fail with a permission-style error.
        fs.removeItemErrors[paths.projectDir(encoded: appEncoded)] = Boom()

        XCTAssertThrowsError(
            try service(fs).delete(selection: select(appEncoded), operation: .claudeDataOnly, dryRun: false)
        ) { error in
            XCTAssertEqual(error as? DeleteError, .removeFailed(paths.projectDir(encoded: appEncoded)))
        }
    }

    func testWriteBackFailureThrowsDeleteErrorAfterDataRemoved() throws {
        struct Boom: Error {}
        let fs = twoProjects()
        // The data removal succeeds; the end-of-run ~/.claude.json write-back fails.
        fs.writeDataErrors[paths.claudeJSON] = Boom()

        XCTAssertThrowsError(
            try service(fs).delete(selection: select(appEncoded), operation: .claudeDataOnly, dryRun: false)
        ) { error in
            XCTAssertEqual(error as? DeleteError, .writeFailed(paths.claudeJSON))
        }

        // No rollback: the already-removed Claude data stays gone even though the
        // write-back failed.
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: appEncoded)))
        XCTAssertFalse(fs.exists(paths.fileHistoryDir(uuid: appUUID)))
    }

    // MARK: - Raced-away path is advisory, not fatal

    func testRacedAwayDataPathWarnsAndContinues() throws {
        let fs = twoProjects()
        // One discovered data path vanishes between discovery and removal.
        let raced = paths.fileHistoryDir(uuid: appUUID)
        fs.removeItemErrors[raced] = FileSystemError.notFound(raced)

        let report = try service(fs).delete(
            selection: select(appEncoded), operation: .claudeDataOnly, dryRun: false
        )

        // The run completes: advisory warning, project still reported deleted.
        XCTAssertEqual(report.warnings, ["path already gone, skipped: \(raced)"])
        XCTAssertEqual(report.deletedProjects.count, 1)
        XCTAssertTrue(report.skippedProjects.isEmpty)

        // The remaining data paths and the JSON key are still removed.
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: appEncoded)))
        XCTAssertFalse(fs.exists(KnownPaths.join(paths.todosDir, "\(appUUID).json")))
        let doc = try JSONValue(data: fs.readData(paths.claudeJSON))
        XCTAssertNil(doc["projects"]?.objectValue?[appPath])
    }

    // MARK: - Multiple projects in one run (batched write-back)

    func testDeletingTwoProjectsRemovesBothKeysWithOneWrite() throws {
        let fs = twoProjects()

        let report = try service(fs).delete(
            selection: select(appEncoded, libEncoded), operation: .entireProject, dryRun: false
        )

        XCTAssertEqual(report.deletedProjects.count, 2)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertTrue(report.skippedProjects.isEmpty)

        // Both projects' data and folders are gone.
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: appEncoded)))
        XCTAssertFalse(fs.exists(paths.projectDir(encoded: libEncoded)))
        XCTAssertFalse(fs.exists(appPath))
        XCTAssertFalse(fs.exists(libPath))

        // Both keys removed; the unknown top-level key survives.
        let doc = try JSONValue(data: fs.readData(paths.claudeJSON))
        let projects = try XCTUnwrap(doc["projects"]?.objectValue)
        XCTAssertNil(projects[appPath])
        XCTAssertNil(projects[libPath])
        XCTAssertEqual(doc["mcpServers"], .object(["git": .object([:])]))

        // The batched write-back touches ~/.claude.json exactly once.
        let writes = fs.journal.filter { $0 == .writeData(paths.claudeJSON) }
        XCTAssertEqual(writes.count, 1)
    }

    // MARK: - Journal: exact removed set, never scans home

    func testRemovedPathSetMatchesAndNeverScansHome() throws {
        let fs = twoProjects()
        _ = try service(fs).delete(
            selection: select(appEncoded), operation: .entireProject, dryRun: false
        )

        let removed = Set(fs.journal.compactMap { access -> String? in
            if case .removeItem(let p) = access { return p }
            return nil
        })
        XCTAssertEqual(removed, Set(appDataPaths() + [appPath]))
        XCTAssertFalse(fs.journal.contains(.listDirectory(home)))
    }

    // MARK: - Pre-run status agrees with execution-time guards

    func testExecutionGuardsAgreeWithManagePlanStatus() throws {
        // Build a mixed fixture and assert that, for each project, the folder-removed
        // outcome of a real "entirely" run agrees with ManagePlan's pre-run status.
        let normal = "/Users/alice/git/Normal"
        let missing = "/Users/alice/git/Missing"
        let linked = "/Users/alice/git/Linked"
        let cases: [(path: String, seed: (InMemoryFileSystem) -> Void, expectFolder: Bool)] = [
            (normal, { $0.seedDirectory(normal) }, true),
            (missing, { _ in }, false),
            (linked, { $0.seedSymlink(linked) }, false),
            (home, { _ in }, false), // unsafe
        ]

        for c in cases {
            let encoded = ProjectPathEncoding.encode(c.path)
            let fs = InMemoryFileSystem()
            fs.seedFile("\(home)/.claude.json", #"{"projects":{"\#(c.path)":{}}}"#)
            fs.seedFile("\(home)/.claude/projects/\(encoded)/s.jsonl", "x")
            c.seed(fs)

            let plan = try ManagePlan(fileSystem: fs, paths: paths)
            let planDeletable = plan.folderStatuses[encoded] == .deletable

            let report = try service(fs).delete(
                selection: select(encoded), operation: .entireProject, dryRun: false
            )
            let folderRemoved = report.deletedProjects.first?.folderRemoved ?? false

            XCTAssertEqual(planDeletable, folderRemoved, "disagreement for \(c.path)")
            XCTAssertEqual(folderRemoved, c.expectFolder, "unexpected outcome for \(c.path)")
        }
    }
}
