import XCTest
@testable import CCSyncCore

final class RestoreServiceTests: XCTestCase {

    private struct StubProvider: ClaudeVersionProvider {
        let version: String?
        func currentVersion() -> String? { version }
    }

    private let fixedTimestamp = "20260708-120000"

    // MARK: - Archive fixtures

    /// An archive from source user `alice` with global config and two projects,
    /// each carrying a main session; `App` also carries a sub-agent session.
    private func sampleArchive(sourceVersion: String? = "1.2.3") throws -> Data {
        let global = GlobalConfig(
            settings: Data(#"{"theme":"dark"}"#.utf8),
            claudeMD: Data("# global rules".utf8),
            configDirs: [
                ConfigDir(name: "commands", files: [
                    FileBlob(relativePath: "deploy.md", data: Data("run deploy".utf8))
                ])
            ],
            mcpServers: .object(["git": .object(["command": .string("git-mcp")])])
        )

        let appMain = SessionArtifacts(
            sessionID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            isSubAgent: false,
            transcript: FileBlob(
                relativePath: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl",
                data: Data(#"{"cwd":"/Users/alice/git/App"}"#.utf8)
            ),
            fileHistory: [FileBlob(relativePath: "edit-1.json", data: Data("fh".utf8))],
            sessionEnv: [FileBlob(relativePath: "env.json", data: Data("env".utf8))],
            todos: [FileBlob(
                relativePath: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.json",
                data: Data("todos".utf8)
            )]
        )
        let appSub = SessionArtifacts(
            sessionID: "agent-xyz",
            isSubAgent: true,
            transcript: FileBlob(relativePath: "agent-xyz.jsonl", data: Data("sub-transcript".utf8)),
            fileHistory: [FileBlob(relativePath: "edit-sub.json", data: Data("fh-sub".utf8))]
        )
        let app = ProjectEntry(
            path: "/Users/alice/git/App",
            encodedName: "-Users-alice-git-App",
            settings: .object(["allowedTools": .array([.string("Bash")])]),
            localSettings: Data(#"{"local":true}"#.utf8),
            sessions: [appMain, appSub]
        )

        let webMain = SessionArtifacts(
            sessionID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            isSubAgent: false,
            transcript: FileBlob(
                relativePath: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl",
                data: Data("web-transcript".utf8)
            )
        )
        let web = ProjectEntry(
            path: "/Users/alice/git/Web",
            encodedName: "-Users-alice-git-Web",
            settings: .object(["allowedTools": .array([.string("Read")])]),
            sessions: [webMain]
        )

        let model = BackupModel(sourceUser: "alice", global: global, projects: [app, web])
        return try ArchiveWriter().makeArchive(from: model, sourceClaudeVersion: sourceVersion)
    }

    private func service(
        fs: InMemoryFileSystem,
        home: String,
        version: String? = nil
    ) -> RestoreService {
        RestoreService(
            fileSystem: fs,
            paths: KnownPaths(home: home),
            versionProvider: version.map(StubProvider.init(version:)),
            snapshotTimestamp: fixedTimestamp
        )
    }

    private func selection(global: Bool, projects: Set<String>) -> Selection {
        Selection(global: global, projectEncodedNames: projects)
    }

    // MARK: - Acceptance 2: only the selected project

    func testRestoreOnlySelectedProjectLeavesGlobalAndOthersUntouched() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        // Both project working folders exist locally.
        fs.seedDirectory("\(home)/git/App")
        fs.seedDirectory("\(home)/git/Web")
        // Pre-existing global settings and an unrelated project entry that must survive.
        fs.seedFile("\(home)/.claude/settings.json", #"{"theme":"light"}"#)
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"/Users/alice/git/Other":{"allowedTools":["Edit"]}}}"#)

        let report = try service(fs: fs, home: home).restore(
            archive: try sampleArchive(),
            selection: selection(global: false, projects: ["-Users-alice-git-App"])
        )

        XCTAssertFalse(report.globalRestored)
        XCTAssertEqual(report.restoredProjects, ["/Users/alice/git/App"])

        // Global settings untouched (global not selected).
        XCTAssertEqual(try fs.readData("\(home)/.claude/settings.json"), Data(#"{"theme":"light"}"#.utf8))

        // ~/.claude.json: App entry added, Other preserved, Web not added.
        let json = try JSONValue(data: fs.readData("\(home)/.claude.json"))
        let projects = try XCTUnwrap(json["projects"]?.objectValue)
        XCTAssertNotNil(projects["/Users/alice/git/App"])
        XCTAssertNotNil(projects["/Users/alice/git/Other"])
        XCTAssertNil(projects["/Users/alice/git/Web"])

        // App history present; Web history absent.
        XCTAssertTrue(fs.exists("\(home)/.claude/projects/-Users-alice-git-App/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl"))
        XCTAssertFalse(fs.exists("\(home)/.claude/projects/-Users-alice-git-Web/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl"))
    }

    // MARK: - Acceptance 2 (converse): only global

    func testRestoreOnlyGlobalWithProjectsMasterOff() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/App")
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"/Users/alice/git/Other":{"allowedTools":["Edit"]}}}"#)

        let report = try service(fs: fs, home: home).restore(
            archive: try sampleArchive(),
            // Projects master off is modelled as an empty selected set.
            selection: selection(global: true, projects: [])
        )

        XCTAssertTrue(report.globalRestored)
        XCTAssertTrue(report.restoredProjects.isEmpty)

        // Global config written.
        XCTAssertEqual(try fs.readData("\(home)/.claude/settings.json"), Data(#"{"theme":"dark"}"#.utf8))
        XCTAssertEqual(try fs.readData("\(home)/.claude/CLAUDE.md"), Data("# global rules".utf8))
        XCTAssertEqual(try fs.readData("\(home)/.claude/commands/deploy.md"), Data("run deploy".utf8))

        // Global mcpServers merged; no project entry added.
        let json = try JSONValue(data: fs.readData("\(home)/.claude.json"))
        XCTAssertEqual(json["mcpServers"], .object(["git": .object(["command": .string("git-mcp")])]))
        let projects = try XCTUnwrap(json["projects"]?.objectValue)
        XCTAssertEqual(Array(projects.keys), ["/Users/alice/git/Other"])
    }

    // MARK: - Acceptance 3: different username → remapped path + projects/ dir

    func testDifferentUsernameRemapsPathAndProjectDirButNotRecordInternals() throws {
        let home = "/Users/bob"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/App")

        let report = try service(fs: fs, home: home).restore(
            archive: try sampleArchive(),
            selection: selection(global: false, projects: ["-Users-alice-git-App"])
        )

        XCTAssertEqual(report.restoredProjects, ["/Users/bob/git/App"])

        // Entry keyed by the remapped path.
        let json = try JSONValue(data: fs.readData("\(home)/.claude.json"))
        let projects = try XCTUnwrap(json["projects"]?.objectValue)
        XCTAssertNotNil(projects["/Users/bob/git/App"])
        XCTAssertNil(projects["/Users/alice/git/App"])

        // History under the remapped projects/ directory.
        let transcript = "\(home)/.claude/projects/-Users-bob-git-App/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl"
        XCTAssertTrue(fs.exists(transcript))
        // Internal record paths are deliberately NOT remapped (accepted boundary).
        XCTAssertEqual(try fs.readData(transcript), Data(#"{"cwd":"/Users/alice/git/App"}"#.utf8))

        // Local settings under the remapped project folder.
        XCTAssertEqual(
            try fs.readData("\(home)/git/App/.claude/settings.local.json"),
            Data(#"{"local":true}"#.utf8)
        )
    }

    // MARK: - Orphan history (a projects/ dir with no ~/.claude.json entry)

    func testOrphanHistoryIsRestoredUnderRemappedEncodedDirNotDropped() throws {
        let home = "/Users/bob"
        let fs = InMemoryFileSystem()

        // An orphan: session history exists on the source but there is no
        // ~/.claude.json entry, so it carries no path and no settings. It must
        // still be restored (keyed by its encoded name), not silently skipped.
        let orphanSession = SessionArtifacts(
            sessionID: "cccccccc-cccc-cccc-cccc-cccccccccccc",
            isSubAgent: false,
            transcript: FileBlob(
                relativePath: "cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl",
                data: Data("orphan-transcript".utf8)
            ),
            fileHistory: [FileBlob(relativePath: "edit-o.json", data: Data("fh-o".utf8))]
        )
        let orphan = ProjectEntry(
            path: "",
            encodedName: "-Users-alice-git-Orphan",
            sessions: [orphanSession],
            incomplete: true,
            incompleteReason: "no entry in ~/.claude.json"
        )
        let model = BackupModel(sourceUser: "alice", global: GlobalConfig(), projects: [orphan])
        let archive = try ArchiveWriter().makeArchive(from: model)

        let report = try service(fs: fs, home: home).restore(
            archive: archive,
            selection: selection(global: false, projects: ["-Users-alice-git-Orphan"])
        )

        // Reported as restored under the remapped encoded directory, not skipped.
        XCTAssertTrue(report.skippedProjects.isEmpty)
        XCTAssertEqual(report.restoredProjects, ["\(home)/.claude/projects/-Users-bob-git-Orphan"])

        // Transcript written under the remapped encoded directory.
        let transcript = "\(home)/.claude/projects/-Users-bob-git-Orphan/cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl"
        XCTAssertTrue(fs.exists(transcript))
        XCTAssertEqual(try fs.readData(transcript), Data("orphan-transcript".utf8))

        // File-history restored by session UUID.
        XCTAssertTrue(fs.exists("\(home)/.claude/file-history/cccccccc-cccc-cccc-cccc-cccccccccccc/edit-o.json"))

        // No ~/.claude.json project entry is fabricated for an orphan.
        if fs.exists("\(home)/.claude.json") {
            let json = try JSONValue(data: fs.readData("\(home)/.claude.json"))
            XCTAssertNil(json["projects"]?.objectValue?["-Users-bob-git-Orphan"])
        }
    }

    // MARK: - Security: a hostile archive cannot escape the restore root

    func testTraversalInGlobalDirEntryIsRejected() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        // A config-dir file whose relative path climbs out of ~/.claude and
        // targets an absolute location. Restore must refuse it as corrupt.
        let global = GlobalConfig(
            configDirs: [
                ConfigDir(name: "commands", files: [
                    FileBlob(
                        relativePath: "../../../../../../../../tmp/ccsync-evil",
                        data: Data("pwned".utf8)
                    )
                ])
            ]
        )
        let model = BackupModel(sourceUser: "alice", global: global, projects: [])
        let archive = try ArchiveWriter().makeArchive(from: model)

        XCTAssertThrowsError(
            try service(fs: fs, home: home).restore(
                archive: archive,
                selection: selection(global: true, projects: [])
            )
        ) { error in
            guard case .corrupt = (error as? ArchiveError) else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
        // Nothing was written outside the home tree.
        XCTAssertFalse(fs.exists("/tmp/ccsync-evil"))
    }

    // MARK: - Acceptance 5: one missing project → partial success + report

    func testMissingProjectIsSkippedAndReportedWithoutInterruption() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        // Only App exists locally; Web folder is missing.
        fs.seedDirectory("\(home)/git/App")

        let report = try service(fs: fs, home: home).restore(
            archive: try sampleArchive(),
            selection: selection(global: false, projects: ["-Users-alice-git-App", "-Users-alice-git-Web"])
        )

        XCTAssertEqual(report.restoredProjects, ["/Users/alice/git/App"])
        XCTAssertEqual(report.skippedProjects.count, 1)
        let skipped = try XCTUnwrap(report.skippedProjects.first)
        XCTAssertEqual(skipped.path, "/Users/alice/git/Web")
        XCTAssertEqual(skipped.encodedName, "-Users-alice-git-Web")
        XCTAssertFalse(skipped.reason.isEmpty)

        // The missing project left no entry, no history, no garbage.
        let json = try JSONValue(data: fs.readData("\(home)/.claude.json"))
        XCTAssertNil(json["projects"]?.objectValue?["/Users/alice/git/Web"])
        XCTAssertFalse(fs.exists("\(home)/.claude/projects/-Users-alice-git-Web"))
    }

    // MARK: - Acceptance 6: idempotence + snapshot before overwrite

    func testRepeatedRestoreIsIdempotentAndSnapshotsBeforeOverwrite() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/App")
        fs.seedDirectory("\(home)/git/Web")
        // Pre-existing files that will be overwritten → must be snapshotted.
        fs.seedFile("\(home)/.claude/settings.json", #"{"theme":"light"}"#)
        fs.seedFile("\(home)/.claude.json", #"{"projects":{}}"#)

        let archive = try sampleArchive()
        let sel = selection(global: true, projects: ["-Users-alice-git-App", "-Users-alice-git-Web"])

        let report1 = try service(fs: fs, home: home).restore(archive: archive, selection: sel)
        let after1 = restoredState(fs)

        // Snapshot captured the pre-existing settings before overwrite.
        let snapshotRoot = try XCTUnwrap(report1.snapshotPath)
        XCTAssertEqual(snapshotRoot, "\(home)/.claude/.ccsync-backups/\(fixedTimestamp)")
        XCTAssertEqual(
            try fs.readData("\(snapshotRoot)/.claude/settings.json"),
            Data(#"{"theme":"light"}"#.utf8)
        )

        let report2 = try service(fs: fs, home: home).restore(archive: archive, selection: sel)
        let after2 = restoredState(fs)

        XCTAssertEqual(after1, after2, "a repeated restore must be idempotent")
        XCTAssertEqual(report1.restoredProjects.sorted(), report2.restoredProjects.sorted())
    }

    /// Backing-store contents excluding the snapshot subtree — the "real" restored state.
    private func restoredState(_ fs: InMemoryFileSystem) -> [String: Data] {
        fs.allFiles.filter { !$0.key.contains("/.ccsync-backups/") }
    }

    // MARK: - Merge does not overwrite others' entries

    func testProjectMergePreservesExistingEntryKeys() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/App")
        // App already has an entry with an extra key that must survive the merge.
        fs.seedFile("\(home)/.claude.json", #"""
        {"projects":{"/Users/alice/git/App":{"history":[1,2,3],"allowedTools":["Old"]},"/Users/alice/git/Keep":{"allowedTools":["Write"]}}}
        """#)

        _ = try service(fs: fs, home: home).restore(
            archive: try sampleArchive(),
            selection: selection(global: false, projects: ["-Users-alice-git-App"])
        )

        let json = try JSONValue(data: fs.readData("\(home)/.claude.json"))
        let projects = try XCTUnwrap(json["projects"]?.objectValue)
        // Other project untouched.
        XCTAssertEqual(projects["/Users/alice/git/Keep"], .object(["allowedTools": .array([.string("Write")])]))
        // App merged: incoming allowedTools wins, pre-existing extra key preserved.
        let app = try XCTUnwrap(projects["/Users/alice/git/App"]?.objectValue)
        XCTAssertEqual(app["allowedTools"], .array([.string("Bash")]))
        XCTAssertEqual(app["history"], .array([.int(1), .int(2), .int(3)]))
    }

    // MARK: - Version check is advisory only

    func testVersionMismatchProducesWarningButDoesNotStop() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/App")

        let report = try service(fs: fs, home: home, version: "9.9.9").restore(
            archive: try sampleArchive(sourceVersion: "1.2.3"),
            selection: selection(global: false, projects: ["-Users-alice-git-App"])
        )
        XCTAssertEqual(report.restoredProjects, ["/Users/alice/git/App"])
        XCTAssertFalse(report.warnings.isEmpty)
    }

    func testVersionMatchIsSilent() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/App")

        let report = try service(fs: fs, home: home, version: "1.2.3").restore(
            archive: try sampleArchive(sourceVersion: "1.2.3"),
            selection: selection(global: false, projects: ["-Users-alice-git-App"])
        )
        XCTAssertTrue(report.warnings.isEmpty)
    }

    // MARK: - Dedicated history-layout test (main + sub-agent)

    func testHistoryLayoutAfterRestoreIncludingSubAgents() throws {
        let home = "/Users/bob"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/App")

        _ = try service(fs: fs, home: home).restore(
            archive: try sampleArchive(),
            selection: selection(global: false, projects: ["-Users-alice-git-App"])
        )

        let projectDir = "\(home)/.claude/projects/-Users-bob-git-App"
        let main = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        // Main session: transcript under the remapped projects/ dir + linked artifacts by UUID.
        XCTAssertTrue(fs.exists("\(projectDir)/\(main).jsonl"))
        XCTAssertEqual(try fs.readData("\(home)/.claude/file-history/\(main)/edit-1.json"), Data("fh".utf8))
        XCTAssertEqual(try fs.readData("\(home)/.claude/session-env/\(main)/env.json"), Data("env".utf8))
        XCTAssertEqual(try fs.readData("\(home)/.claude/todos/\(main).json"), Data("todos".utf8))

        // Sub-agent session: transcript alongside the main one + its own file-history.
        XCTAssertTrue(fs.exists("\(projectDir)/agent-xyz.jsonl"))
        XCTAssertEqual(
            try fs.readData("\(home)/.claude/file-history/agent-xyz/edit-sub.json"),
            Data("fh-sub".utf8)
        )
    }

    // MARK: - Corrupt archive stops

    func testCorruptArchiveThrows() {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        XCTAssertThrowsError(
            try service(fs: fs, home: home).restore(
                archive: Data("not an archive".utf8),
                selection: selection(global: true, projects: [])
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveError, .notAnArchive)
        }
    }

    // MARK: - Hostile archive path traversal is rejected

    /// A `..` in a global config-dir payload must not escape `~/.claude` (e.g.
    /// `global/dirs/commands/../.credentials.json` overwriting credentials).
    func testGlobalDirsTraversalIsRejected() throws {
        let global = GlobalConfig(
            settings: nil,
            claudeMD: nil,
            configDirs: [
                ConfigDir(name: "commands", files: [
                    FileBlob(relativePath: "../.credentials.json", data: Data("EVIL".utf8))
                ])
            ],
            mcpServers: nil
        )
        let archive = try ArchiveWriter().makeArchive(
            from: BackupModel(sourceUser: "alice", global: global, projects: [])
        )
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        XCTAssertThrowsError(
            try service(fs: fs, home: home).restore(
                archive: archive,
                selection: selection(global: true, projects: [])
            )
        ) { error in
            guard case .corrupt = error as? ArchiveError else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
        // The credentials file was never written.
        XCTAssertFalse(fs.exists("\(home)/.claude/.credentials.json"))
    }

    /// A global config-dir payload whose top segment is not a known config dir
    /// must be rejected even without any `..` component — otherwise a hostile
    /// archive could write into e.g. `~/.claude/projects/<encoded>/…`, clobbering
    /// session history the user never selected.
    func testGlobalDirsNonConfigDirNameIsRejected() throws {
        let encoded = "-Users-alice-git-Other"
        let global = GlobalConfig(
            settings: nil,
            claudeMD: nil,
            configDirs: [
                // Masquerades as the `projects` root, not a real config dir.
                ConfigDir(name: "projects", files: [
                    FileBlob(relativePath: "\(encoded)/evil.jsonl", data: Data("EVIL".utf8))
                ])
            ],
            mcpServers: nil
        )
        let archive = try ArchiveWriter().makeArchive(
            from: BackupModel(sourceUser: "alice", global: global, projects: [])
        )
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        XCTAssertThrowsError(
            try service(fs: fs, home: home).restore(
                archive: archive,
                selection: selection(global: true, projects: [])
            )
        ) { error in
            guard case .corrupt = error as? ArchiveError else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
        XCTAssertFalse(fs.exists("\(home)/.claude/projects/\(encoded)/evil.jsonl"))
    }

    /// A `..` embedded in a project's encoded name must not escape `~/.claude`.
    func testProjectEncodedNameTraversalIsRejected() throws {
        let evil = ProjectEntry(
            path: "/Users/alice/git/Evil",
            encodedName: "../../../../tmp/evil",
            settings: nil,
            localSettings: nil,
            sessions: [SessionArtifacts(
                sessionID: "cccccccc-cccc-cccc-cccc-cccccccccccc",
                isSubAgent: false,
                transcript: FileBlob(relativePath: "t.jsonl", data: Data("x".utf8))
            )]
        )
        let archive = try ArchiveWriter().makeArchive(
            from: BackupModel(sourceUser: "alice", global: GlobalConfig(), projects: [evil])
        )
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/Evil")
        XCTAssertThrowsError(
            try service(fs: fs, home: home).restore(
                archive: archive,
                selection: selection(global: false, projects: ["../../../../tmp/evil"])
            )
        ) { error in
            guard case .corrupt = error as? ArchiveError else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
    }

    // MARK: - A symlink already on the target must not be written through

    /// `KnownPaths.isContained` is purely lexical and `FileSystem.writeData`
    /// follows symlinks. A global config file that already exists on the target
    /// as a symlink must be rejected, not written through to its target.
    func testSymlinkedGlobalTargetIsRejected() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        // The target already has `~/.claude/settings.json` as a symlink.
        fs.seedSymlink("\(home)/.claude/settings.json")

        XCTAssertThrowsError(
            try service(fs: fs, home: home).restore(
                archive: try sampleArchive(),
                selection: selection(global: true, projects: [])
            )
        ) { error in
            guard case .corrupt = error as? ArchiveError else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
        // The write never happened.
        XCTAssertFalse(fs.journal.contains(.writeData("\(home)/.claude/settings.json")))
    }

    /// A symlinked *parent component* beneath the restore root is equally unsafe:
    /// writing a history file under a symlinked `~/.claude/projects` would escape.
    func testSymlinkedParentComponentIsRejected() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/App")
        fs.seedDirectory("\(home)/git/Web")
        // `~/.claude/projects` itself is a symlink pointing elsewhere.
        fs.seedSymlink("\(home)/.claude/projects")

        XCTAssertThrowsError(
            try service(fs: fs, home: home).restore(
                archive: try sampleArchive(),
                selection: selection(global: false, projects: ["-Users-alice-git-App"])
            )
        ) { error in
            guard case .corrupt = error as? ArchiveError else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
    }

    /// A symlinked global config-dir *root* (e.g. `~/.claude/commands`) must be
    /// rejected too. The symlink walk starts below its containment root, so if
    /// the write were contained against `~/.claude/commands` the root symlink
    /// would never be checked and `writeData` would follow it outside `~/.claude`.
    func testSymlinkedGlobalConfigDirRootIsRejected() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        // `~/.claude/commands` itself is a symlink pointing elsewhere. The
        // sample archive carries `global/dirs/commands/deploy.md`.
        fs.seedSymlink("\(home)/.claude/commands")

        XCTAssertThrowsError(
            try service(fs: fs, home: home).restore(
                archive: try sampleArchive(),
                selection: selection(global: true, projects: [])
            )
        ) { error in
            guard case .corrupt = error as? ArchiveError else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
        // The write through the symlinked dir never happened.
        XCTAssertFalse(fs.journal.contains(.writeData("\(home)/.claude/commands/deploy.md")))
    }

    /// A symlinked `~/.claude.json` on the target must not be written through
    /// when a project entry is merged into it.
    func testSymlinkedClaudeJSONTargetIsRejected() throws {
        let home = "/Users/alice"
        let fs = InMemoryFileSystem()
        fs.seedDirectory("\(home)/git/App")
        fs.seedSymlink("\(home)/.claude.json")

        XCTAssertThrowsError(
            try service(fs: fs, home: home).restore(
                archive: try sampleArchive(),
                selection: selection(global: false, projects: ["-Users-alice-git-App"])
            )
        ) { error in
            guard case .corrupt = error as? ArchiveError else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
        XCTAssertFalse(fs.journal.contains(.writeData("\(home)/.claude.json")))
    }
}
