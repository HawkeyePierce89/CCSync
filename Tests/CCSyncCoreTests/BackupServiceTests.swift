import XCTest
@testable import CCSyncCore

final class BackupServiceTests: XCTestCase {

    private let home = "/Users/alice"
    private var paths: KnownPaths { KnownPaths(home: home) }

    // A fixture home with global config, a project with a main + sub-agent
    // session and their linked artifacts, plus excluded noise.
    private func seedFixture(_ fs: InMemoryFileSystem) {
        fs.seedFile("\(home)/.claude/settings.json", #"{"theme":"dark"}"#)
        fs.seedFile("\(home)/.claude/CLAUDE.md", "# Global rules")
        fs.seedFile("\(home)/.claude/commands/deploy.md", "run deploy")
        fs.seedFile("\(home)/.claude.json", #"""
        {"mcpServers":{"git":{"command":"git-mcp"}},"projects":{"/Users/alice/git/App":{"allowedTools":["Bash"]}}}
        """#)
        fs.seedFile("\(home)/git/App/.claude/settings.local.json", #"{"local":true}"#)

        let encoded = "-Users-alice-git-App"
        let main = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        fs.seedFile("\(home)/.claude/projects/\(encoded)/\(main).jsonl", "main-transcript")
        fs.seedFile("\(home)/.claude/projects/\(encoded)/agent-xyz.jsonl", "sub-transcript")
        fs.seedFile("\(home)/.claude/file-history/\(main)/edit-1.json", "fh")
        fs.seedFile("\(home)/.claude/session-env/\(main)/env.json", "env")
        fs.seedFile("\(home)/.claude/todos/\(main).json", "todos")

        // Excluded credentials & local noise — must never reach the archive.
        fs.seedFile("\(home)/.claude/.credentials.json", "SECRET")
        fs.seedFile("\(home)/.claude/history.jsonl", "local history")
        fs.seedFile("\(home)/.claude/statsig/evaluations", "telemetry")
        fs.seedFile("\(home)/.claude/cache/blob", "noise")
    }

    private func unpack(_ data: Data) throws -> [String: Data] {
        var byPath: [String: Data] = [:]
        for entry in try ArchiveContainer.unpack(data) { byPath[entry.path] = entry.data }
        return byPath
    }

    // MARK: - Archive contents

    func testArchiveContainsManifestGlobalAndHistory() throws {
        let fs = InMemoryFileSystem()
        seedFixture(fs)

        let archive = try ArchiveWriter().makeArchive(
            from: try BackupCollector(fileSystem: fs, paths: paths).collect(),
            sourceClaudeVersion: "1.2.3"
        )
        let entries = try unpack(archive)
        let encoded = "-Users-alice-git-App"

        // Manifest present and well-formed.
        let manifest = try Manifest(data: try XCTUnwrap(entries[ArchiveLayout.manifest]))
        XCTAssertEqual(manifest.formatVersion, Manifest.currentFormatVersion)
        XCTAssertEqual(manifest.sourceUser, "alice")
        XCTAssertEqual(manifest.sourceClaudeVersion, "1.2.3")
        XCTAssertEqual(manifest.projects.count, 1)
        let project = try XCTUnwrap(manifest.projects.first)
        XCTAssertEqual(project.path, "/Users/alice/git/App")
        XCTAssertEqual(project.encodedName, encoded)
        XCTAssertFalse(project.incomplete)
        XCTAssertEqual(project.settings, JSONValue.object([
            "allowedTools": .array([.string("Bash")])
        ]))

        // Global config.
        XCTAssertEqual(entries["global/settings.json"], Data(#"{"theme":"dark"}"#.utf8))
        XCTAssertEqual(entries["global/CLAUDE.md"], Data("# Global rules".utf8))
        XCTAssertEqual(entries["global/dirs/commands/deploy.md"], Data("run deploy".utf8))
        let mcp = try JSONValue(data: try XCTUnwrap(entries["global/mcpServers.json"]))
        XCTAssertEqual(mcp, JSONValue.object(["git": .object(["command": .string("git-mcp")])]))

        // Project payload: local settings + main and sub-agent history.
        XCTAssertEqual(entries["projects/\(encoded)/settings.local.json"], Data(#"{"local":true}"#.utf8))
        let main = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        XCTAssertEqual(
            entries["projects/\(encoded)/sessions/\(main)/transcript/\(main).jsonl"],
            Data("main-transcript".utf8)
        )
        XCTAssertEqual(
            entries["projects/\(encoded)/sessions/agent-xyz/transcript/agent-xyz.jsonl"],
            Data("sub-transcript".utf8)
        )
        XCTAssertEqual(entries["projects/\(encoded)/sessions/\(main)/file-history/edit-1.json"], Data("fh".utf8))
        XCTAssertEqual(entries["projects/\(encoded)/sessions/\(main)/session-env/env.json"], Data("env".utf8))
        XCTAssertEqual(entries["projects/\(encoded)/sessions/\(main)/todos/\(main).json"], Data("todos".utf8))
    }

    func testArchiveExcludesCredentialsAndNoise() throws {
        let fs = InMemoryFileSystem()
        seedFixture(fs)

        let archive = try ArchiveWriter().makeArchive(
            from: try BackupCollector(fileSystem: fs, paths: paths).collect()
        )
        let entries = try unpack(archive)

        for path in entries.keys {
            for banned in [".credentials", "history.jsonl", "statsig", "cache"] {
                XCTAssertFalse(path.contains(banned), "archive contains excluded path: \(path)")
            }
        }
        // And no payload bytes leaked the secret.
        for data in entries.values {
            XCTAssertNil(String(data: data, encoding: .utf8).flatMap { $0.contains("SECRET") ? $0 : nil },
                         "archive payload leaked a secret")
        }
    }

    // MARK: - Round-trip consistency

    func testUnpackingBackYieldsConsistentStructure() throws {
        let fs = InMemoryFileSystem()
        seedFixture(fs)
        let model = try BackupCollector(fileSystem: fs, paths: paths).collect()
        let archive = try ArchiveWriter().makeArchive(from: model)

        let entries = try unpack(archive)
        // Manifest project list mirrors the collected model exactly.
        let manifest = try Manifest(data: try XCTUnwrap(entries[ArchiveLayout.manifest]))
        XCTAssertEqual(
            manifest.projects.map(\.encodedName),
            model.projects.map(\.encodedName)
        )
        XCTAssertEqual(
            manifest.projects.map(\.incomplete),
            model.projects.map(\.incomplete)
        )
        // Every collected session's transcript is present in the payload.
        for project in model.projects {
            for session in project.sessions {
                let key = "projects/\(project.encodedName)/sessions/\(session.sessionID)/transcript/\(session.transcript.relativePath)"
                XCTAssertEqual(entries[key], session.transcript.data)
            }
        }
    }

    // MARK: - BackupService end-to-end (in memory)

    func testBackupServiceWritesArchiveToDefaultHomeDestination() throws {
        let fs = InMemoryFileSystem()
        seedFixture(fs)

        let dest = try BackupService(fileSystem: fs, paths: paths).backup()
        XCTAssertEqual(dest, "\(home)/\(BackupService.defaultFileName)")
        // The archive was written through the FileSystem abstraction.
        XCTAssertTrue(fs.journal.contains(.writeData(dest)))

        // What was written is a valid archive with a parseable manifest.
        let written = try fs.readData(dest)
        let entries = try unpack(written)
        XCTAssertNotNil(entries[ArchiveLayout.manifest])
        _ = try Manifest(data: try XCTUnwrap(entries[ArchiveLayout.manifest]))
    }

    func testBackupServiceHonoursExplicitDestination() throws {
        let fs = InMemoryFileSystem()
        seedFixture(fs)

        let target = "/Users/alice/Desktop/my-backup.ccsync"
        let dest = try BackupService(fileSystem: fs, paths: paths).backup(to: target)
        XCTAssertEqual(dest, target)
        XCTAssertNoThrow(try ArchiveContainer.unpack(try fs.readData(target)))
    }

    func testBackupServiceWritesIntoDirectoryDestination() throws {
        let fs = InMemoryFileSystem()
        seedFixture(fs)
        fs.seedDirectory("/Users/alice/Desktop")

        let dest = try BackupService(fileSystem: fs, paths: paths).backup(to: "/Users/alice/Desktop")
        XCTAssertEqual(dest, "/Users/alice/Desktop/\(BackupService.defaultFileName)")
    }

    // MARK: - Selective round-trip

    // A fixture with two full projects (folder + entry + session + local
    // settings) alongside the global config.
    private func seedTwoProjects(_ fs: InMemoryFileSystem) {
        fs.seedFile("\(home)/.claude/settings.json", #"{"theme":"dark"}"#)
        fs.seedFile("\(home)/.claude/CLAUDE.md", "# Global rules")
        fs.seedFile("\(home)/.claude/commands/deploy.md", "run deploy")
        fs.seedFile("\(home)/.claude.json", #"""
        {"mcpServers":{"git":{"command":"git-mcp"}},"projects":{"/Users/alice/git/App":{"allowedTools":["Bash"]},"/Users/alice/git/Lib":{"allowedTools":["Read"]}}}
        """#)
        fs.seedFile("\(home)/git/App/.claude/settings.local.json", #"{"app":true}"#)
        fs.seedFile("\(home)/git/Lib/.claude/settings.local.json", #"{"lib":true}"#)
        fs.seedFile("\(home)/.claude/projects/-Users-alice-git-App/\("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").jsonl", "app-transcript")
        fs.seedFile("\(home)/.claude/projects/-Users-alice-git-Lib/\("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb").jsonl", "lib-transcript")
    }

    func testSelectiveArchiveRoundTripsOneProject() throws {
        let fs = InMemoryFileSystem()
        seedTwoProjects(fs)

        // Collect only "App".
        let selection = Selection(global: true, projectEncodedNames: ["-Users-alice-git-App"])
        let model = try BackupCollector(fileSystem: fs, paths: paths).collect(selection: selection)
        let archive = try ArchiveWriter().makeArchive(from: model)

        // The archive lacks the unselected project entirely (checked via RestorePlan).
        let plan = try RestorePlan(archive: archive)
        XCTAssertEqual(plan.projects.map(\.encodedName), ["-Users-alice-git-App"])

        // Restore the single-project archive and confirm "App" landed.
        let report = try RestoreService(fileSystem: fs, paths: paths)
            .restore(archive: archive, selection: selection)
        XCTAssertTrue(report.restoredProjects.contains("/Users/alice/git/App"))
        XCTAssertTrue(report.globalRestored)
    }

    // MARK: - No-global round-trip

    func testNoGlobalArchiveRestoresWithoutClobberingLiveGlobalConfig() throws {
        let fs = InMemoryFileSystem()
        // A live, non-empty target home the restore could clobber.
        fs.seedFile("\(home)/.claude/settings.json", #"{"theme":"light"}"#)
        fs.seedFile("\(home)/.claude/CLAUDE.md", "# live rules")
        fs.seedFile("\(home)/.claude/commands/live.md", "live command")
        fs.seedFile("\(home)/.claude.json", #"{"mcpServers":{"git":{"command":"git-mcp"}},"projects":{}}"#)
        // Orphan history (no `~/.claude.json` entry) so project restore never
        // touches `~/.claude.json` — isolating the global-layer assertions.
        let encoded = "-Users-alice-git-Orphan"
        let uuid = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        fs.seedFile("\(home)/.claude/projects/\(encoded)/\(uuid).jsonl", "orphan-transcript")

        // Collect with global OFF; the orphan project is selected.
        let backupSelection = Selection(global: false, projectEncodedNames: [encoded])
        let model = try BackupCollector(fileSystem: fs, paths: paths).collect(selection: backupSelection)
        let archive = try ArchiveWriter().makeArchive(from: model)

        // Restore with global ON on the live home.
        let restoreSelection = Selection(global: true, projectEncodedNames: [encoded])
        let report = try RestoreService(fileSystem: fs, paths: paths)
            .restore(archive: archive, selection: restoreSelection)

        // An empty global layer never clobbers a live config: no global path written.
        XCTAssertFalse(fs.journal.contains(.writeData("\(home)/.claude/settings.json")))
        XCTAssertFalse(fs.journal.contains(.writeData("\(home)/.claude/CLAUDE.md")))
        for name in KnownPaths.globalConfigDirNames {
            for access in fs.journal {
                guard case .writeData(let path) = access else { continue }
                XCTAssertFalse(
                    path.hasPrefix("\(home)/.claude/\(name)/"),
                    "empty global layer wrote into config dir \(name): \(path)"
                )
            }
        }
        // No `~/.claude.json` write at all (no project merge, no mcpServers merge).
        XCTAssertFalse(fs.journal.contains(.writeData("\(home)/.claude.json")))

        // Positive control: the selected project's history was restored — restore
        // did run through the global branch.
        XCTAssertTrue(report.restoredProjects.contains(paths.projectDir(encoded: encoded)))
        XCTAssertEqual(
            try fs.readData("\(home)/.claude/projects/\(encoded)/\(uuid).jsonl"),
            Data("orphan-transcript".utf8)
        )

        // An empty global layer writes nothing, so `globalRestored` is false even
        // though `selection.global == true` — it reports a real write, not a mere
        // selection.
        XCTAssertFalse(report.globalRestored)
    }

    // MARK: - Container round-trip

    func testContainerPackUnpackRoundTrip() throws {
        let entries = [
            ArchiveContainer.Entry(path: "a.txt", data: Data("hello".utf8)),
            ArchiveContainer.Entry(path: "nested/b.bin", data: Data([0x00, 0xFF, 0x10, 0x42])),
            ArchiveContainer.Entry(path: "empty", data: Data()),
        ]
        let packed = ArchiveContainer.pack(entries)
        XCTAssertEqual(try ArchiveContainer.unpack(packed), entries)
    }

    func testContainerRejectsNonArchiveBytes() {
        XCTAssertThrowsError(try ArchiveContainer.unpack(Data("not an archive".utf8))) { error in
            XCTAssertEqual(error as? ArchiveError, .notAnArchive)
        }
    }
}
