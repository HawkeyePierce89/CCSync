import XCTest
@testable import CCSyncCore

final class BackupCollectorTests: XCTestCase {

    private let home = "/Users/alice"
    private var paths: KnownPaths { KnownPaths(home: home) }

    private func makeCollector(_ fs: InMemoryFileSystem) -> BackupCollector {
        BackupCollector(fileSystem: fs, paths: paths)
    }

    // MARK: - Global config

    func testCollectsGlobalConfigAndSkipsMissingDirs() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude/settings.json", #"{"theme":"dark"}"#)
        fs.seedFile("\(home)/.claude/CLAUDE.md", "# Global rules")
        fs.seedFile("\(home)/.claude/commands/deploy.md", "run deploy")
        fs.seedFile("\(home)/.claude/skills/foo/skill.md", "a skill")
        fs.seedFile("\(home)/.claude.json", #"{"mcpServers":{"git":{"command":"git-mcp"}}}"#)

        let model = try makeCollector(fs).collect()

        XCTAssertEqual(model.sourceUser, "alice")
        XCTAssertEqual(model.global.settings, Data(#"{"theme":"dark"}"#.utf8))
        XCTAssertEqual(model.global.claudeMD, Data("# Global rules".utf8))

        let dirNames = model.global.configDirs.map(\.name).sorted()
        XCTAssertEqual(dirNames, ["commands", "skills"])
        // Missing dirs (agents, rules, output-styles, hooks) are absent, not empty.

        let skills = model.global.configDirs.first { $0.name == "skills" }
        XCTAssertEqual(skills?.files.map(\.relativePath), ["foo/skill.md"])

        XCTAssertEqual(model.global.mcpServers, JSONValue.object([
            "git": .object(["command": .string("git-mcp")])
        ]))
    }

    func testSymlinkedEntriesAreNeverFollowed() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude/settings.json", "{}")
        fs.seedFile("\(home)/.claude/commands/real.md", "genuine")
        // A symlink planted under a known root must not be followed (it could
        // redirect collection outside the approved paths or form a cycle).
        fs.seedSymlink("\(home)/.claude/commands/escape.md")

        let model = try makeCollector(fs).collect()

        let commands = model.global.configDirs.first { $0.name == "commands" }
        XCTAssertEqual(commands?.files.map(\.relativePath), ["real.md"])
        // The symlink's contents were never read.
        XCTAssertFalse(fs.journal.contains(.readData("\(home)/.claude/commands/escape.md")))
    }

    func testSymlinkedDirectoryRootIsNeverListed() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude/settings.json", "{}")
        // `commands` is itself a symlink pointing at a directory. `isDirectory`
        // follows symlinks, so without an explicit symlink guard on the root the
        // collector would enter it and scan the target (`leaked.md` here),
        // redirecting collection outside the approved paths.
        let commandsDir = "\(home)/.claude/commands"
        fs.seedFile("\(commandsDir)/leaked.md", "outside approved roots")
        fs.seedSymlink(commandsDir)

        let model = try makeCollector(fs).collect()

        // The symlinked root was skipped entirely.
        XCTAssertNil(model.global.configDirs.first { $0.name == "commands" })
        XCTAssertFalse(fs.journal.contains(.listDirectory(commandsDir)))
        XCTAssertFalse(fs.journal.contains(.readData("\(commandsDir)/leaked.md")))
    }

    func testSymlinkedDirectReadFilesAreNeverFollowed() throws {
        let fs = InMemoryFileSystem()
        // Every fixed known path we read directly (after only an `exists` check)
        // is planted as a symlink. `RealFileSystem.readData` follows symlinks, so
        // without a no-follow guard each would siphon an outside file into the
        // archive. Restore-independent regression for the direct-read paths.
        fs.seedSymlink("\(home)/.claude.json")
        fs.seedSymlink("\(home)/.claude/settings.json")
        fs.seedSymlink("\(home)/.claude/CLAUDE.md")
        let projectPath = "/Users/alice/git/App"
        fs.seedSymlink("\(projectPath)/.claude/settings.local.json")

        let model = try makeCollector(fs).collect()

        // None of the symlinked known paths were read.
        XCTAssertFalse(fs.journal.contains(.readData("\(home)/.claude.json")))
        XCTAssertFalse(fs.journal.contains(.readData("\(home)/.claude/settings.json")))
        XCTAssertFalse(fs.journal.contains(.readData("\(home)/.claude/CLAUDE.md")))
        XCTAssertFalse(fs.journal.contains(.readData("\(projectPath)/.claude/settings.local.json")))

        // A symlinked known path is treated as absent, not captured.
        XCTAssertNil(model.global.settings)
        XCTAssertNil(model.global.claudeMD)
    }

    func testOptionalGlobalFilesAbsent() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude/settings.json", "{}")
        // No CLAUDE.md, no config dirs, no ~/.claude.json.

        let model = try makeCollector(fs).collect()
        XCTAssertNil(model.global.claudeMD)
        XCTAssertTrue(model.global.configDirs.isEmpty)
        XCTAssertNil(model.global.mcpServers)
        XCTAssertTrue(model.projects.isEmpty)
    }

    // MARK: - Excludes credentials & local noise

    func testExcludedNoiseIsNeverTouched() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude/settings.json", "{}")
        fs.seedFile("\(home)/.claude/.credentials.json", "SECRET")
        fs.seedFile("\(home)/.claude/history.jsonl", "local history")
        fs.seedFile("\(home)/.claude/statsig/evaluations", "telemetry")
        fs.seedFile("\(home)/.claude/shell-snapshots/snap.sh", "noise")
        fs.seedFile("\(home)/.claude/cache/blob", "noise")

        _ = try makeCollector(fs).collect()

        for access in fs.journal {
            for excluded in ["/.credentials.json", "/history.jsonl", "/statsig", "/shell-snapshots", "/cache/"] {
                XCTAssertFalse(
                    access.path.contains(excluded),
                    "collector touched excluded path: \(access.path)"
                )
            }
        }
    }

    // MARK: - Project entry + local settings + history

    func testCollectsProjectEntryLocalSettingsAndSession() throws {
        let fs = InMemoryFileSystem()
        let projectPath = "/Users/alice/git/App"
        let encoded = "-Users-alice-git-App"
        fs.seedFile("\(home)/.claude/settings.json", "{}")
        fs.seedFile("\(home)/.claude.json", """
        {"projects":{"\(projectPath)":{"allowedTools":["Bash"]}}}
        """)
        fs.seedFile("\(projectPath)/.claude/settings.local.json", #"{"local":true}"#)
        fs.seedFile("\(home)/.claude/projects/\(encoded)/11111111-1111-1111-1111-111111111111.jsonl", "line")

        let model = try makeCollector(fs).collect()

        XCTAssertEqual(model.projects.count, 1)
        let project = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(project.path, projectPath)
        XCTAssertEqual(project.encodedName, encoded)
        XCTAssertFalse(project.incomplete)
        XCTAssertEqual(project.settings, JSONValue.object([
            "allowedTools": .array([.string("Bash")])
        ]))
        XCTAssertEqual(project.localSettings, Data(#"{"local":true}"#.utf8))
        XCTAssertEqual(project.sessions.count, 1)
        XCTAssertEqual(project.sessions.first?.sessionID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(project.sessions.first?.isSubAgent, false)
    }

    func testCollectsSubAgentSessionsAndLinkedArtifacts() throws {
        let fs = InMemoryFileSystem()
        let projectPath = "/Users/alice/git/App"
        let encoded = "-Users-alice-git-App"
        let mainUUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let projectDir = "\(home)/.claude/projects/\(encoded)"

        fs.seedFile("\(home)/.claude.json", """
        {"projects":{"\(projectPath)":{}}}
        """)
        fs.seedFile("\(projectDir)/\(mainUUID).jsonl", "main")
        fs.seedFile("\(projectDir)/agent-xyz.jsonl", "subagent")
        // Linked artifacts for the main session.
        fs.seedFile("\(home)/.claude/file-history/\(mainUUID)/edit-1.json", "fh")
        fs.seedFile("\(home)/.claude/session-env/\(mainUUID)/env.json", "env")
        fs.seedFile("\(home)/.claude/todos/\(mainUUID).json", "todos-main")
        fs.seedFile("\(home)/.claude/todos/\(mainUUID)-agent-xyz.json", "todos-agent")

        let model = try makeCollector(fs).collect()
        let project = try XCTUnwrap(model.projects.first)

        XCTAssertEqual(project.sessions.count, 2)
        let main = try XCTUnwrap(project.sessions.first { $0.sessionID == mainUUID })
        let sub = try XCTUnwrap(project.sessions.first { $0.isSubAgent })

        XCTAssertEqual(sub.sessionID, "agent-xyz")
        XCTAssertEqual(main.fileHistory.map(\.relativePath), ["edit-1.json"])
        XCTAssertEqual(main.sessionEnv.map(\.relativePath), ["env.json"])
        XCTAssertEqual(
            main.todos.map(\.relativePath).sorted(),
            ["\(mainUUID)-agent-xyz.json", "\(mainUUID).json"].sorted()
        )
    }

    // MARK: - List / directory mismatch

    func testEntryWithoutHistoryDirectory() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude.json", """
        {"projects":{"/Users/alice/git/Ghost":{"allowedTools":[]}}}
        """)

        let model = try makeCollector(fs).collect()
        let project = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(project.path, "/Users/alice/git/Ghost")
        XCTAssertTrue(project.incomplete)
        XCTAssertEqual(project.incompleteReason, "no history directory on disk")
        XCTAssertTrue(project.sessions.isEmpty)
    }

    func testHistoryDirectoryWithoutEntry() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("\(home)/.claude.json", #"{"projects":{}}"#)
        let encoded = "-Users-alice-git-Orphan"
        fs.seedFile("\(home)/.claude/projects/\(encoded)/22222222-2222-2222-2222-222222222222.jsonl", "x")

        let model = try makeCollector(fs).collect()
        let project = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(project.encodedName, encoded)
        XCTAssertEqual(project.path, "")
        XCTAssertTrue(project.incomplete)
        XCTAssertEqual(project.incompleteReason, "no entry in ~/.claude.json")
        XCTAssertEqual(project.sessions.count, 1)
    }

    // MARK: - Selective collection

    // A fixture with two projects (each a session) plus global config.
    private func seedTwoProjects(_ fs: InMemoryFileSystem) {
        fs.seedFile("\(home)/.claude/settings.json", #"{"theme":"dark"}"#)
        fs.seedFile("\(home)/.claude/CLAUDE.md", "# Global rules")
        fs.seedFile("\(home)/.claude/commands/deploy.md", "run deploy")
        fs.seedFile("\(home)/.claude.json", #"""
        {"mcpServers":{"git":{"command":"git-mcp"}},"projects":{"/Users/alice/git/App":{},"/Users/alice/git/Lib":{}}}
        """#)
        fs.seedFile("\(home)/.claude/projects/-Users-alice-git-App/\("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").jsonl", "app")
        fs.seedFile("\(home)/git/App/.claude/settings.local.json", #"{"app":true}"#)
        fs.seedFile("\(home)/.claude/projects/-Users-alice-git-Lib/\("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb").jsonl", "lib")
        fs.seedFile("\(home)/git/Lib/.claude/settings.local.json", #"{"lib":true}"#)
    }

    func testUnselectedProjectPathsAreNeverRead() throws {
        let fs = InMemoryFileSystem()
        seedTwoProjects(fs)

        // Select only "App"; "Lib" must be cut before any of its paths are read.
        let selection = Selection(global: true, projectEncodedNames: ["-Users-alice-git-App"])
        let model = try makeCollector(fs).collect(selection: selection)

        XCTAssertEqual(model.projects.map(\.encodedName), ["-Users-alice-git-App"])

        // No `.readData` for any path belonging to the unselected "Lib" project.
        for access in fs.journal {
            guard case .readData(let path) = access else { continue }
            XCTAssertFalse(
                path.contains("-Users-alice-git-Lib") || path.contains("/git/Lib/"),
                "collector read an unselected project's path: \(path)"
            )
        }
        // The selected project's session was captured (positive control).
        XCTAssertEqual(model.projects.first?.sessions.count, 1)
    }

    func testGlobalOffSkipsGlobalReadsAndPayload() throws {
        let fs = InMemoryFileSystem()
        seedTwoProjects(fs)

        // Global off, both projects on.
        let selection = Selection(
            global: false,
            projectEncodedNames: ["-Users-alice-git-App", "-Users-alice-git-Lib"]
        )
        let model = try makeCollector(fs).collect(selection: selection)

        // The global layer is empty — nothing was captured.
        XCTAssertNil(model.global.settings)
        XCTAssertNil(model.global.claudeMD)
        XCTAssertTrue(model.global.configDirs.isEmpty)
        XCTAssertNil(model.global.mcpServers)

        // And none of the global paths were read.
        XCTAssertFalse(fs.journal.contains(.readData("\(home)/.claude/settings.json")))
        XCTAssertFalse(fs.journal.contains(.readData("\(home)/.claude/CLAUDE.md")))
        for access in fs.journal {
            XCTAssertFalse(
                access.path.contains("/.claude/commands"),
                "collector touched a global config dir with global off: \(access.path)"
            )
        }
        // Both projects were still collected.
        XCTAssertEqual(
            model.projects.map(\.encodedName).sorted(),
            ["-Users-alice-git-App", "-Users-alice-git-Lib"]
        )
    }

    // MARK: - Journal: only known paths are touched

    func testJournalTouchesOnlyKnownPaths() throws {
        let fs = InMemoryFileSystem()
        let projectPath = "/Users/alice/git/App"
        let encoded = "-Users-alice-git-App"
        fs.seedFile("\(home)/.claude/settings.json", "{}")
        fs.seedFile("\(home)/.claude/commands/c.md", "c")
        fs.seedFile("\(home)/.claude.json", """
        {"mcpServers":{},"projects":{"\(projectPath)":{}}}
        """)
        fs.seedFile("\(projectPath)/.claude/settings.local.json", "{}")
        let uuid = "33333333-3333-3333-3333-333333333333"
        fs.seedFile("\(home)/.claude/projects/\(encoded)/\(uuid).jsonl", "l")
        fs.seedFile("\(home)/.claude/file-history/\(uuid)/e.json", "e")
        // Noise that must never be touched.
        fs.seedFile("\(home)/Documents/secret.txt", "nope")
        fs.seedFile("\(home)/.claude/statsig/x", "nope")

        _ = try makeCollector(fs).collect()

        let allowedPrefixes = [
            "\(home)/.claude/settings.json",
            "\(home)/.claude/CLAUDE.md",
            "\(home)/.claude.json",
            "\(home)/.claude/commands",
            "\(home)/.claude/agents",
            "\(home)/.claude/skills",
            "\(home)/.claude/rules",
            "\(home)/.claude/output-styles",
            "\(home)/.claude/hooks",
            "\(home)/.claude/projects",
            "\(home)/.claude/file-history",
            "\(home)/.claude/session-env",
            "\(home)/.claude/todos",
            "\(projectPath)/.claude/",
        ]

        for access in fs.journal {
            let path = access.path
            let allowed = allowedPrefixes.contains { path == $0 || path.hasPrefix($0) }
            XCTAssertTrue(allowed, "collector touched unexpected path: \(path)")
        }
        // The home directory itself must never be listed (no scanning).
        XCTAssertFalse(fs.journal.contains(.listDirectory(home)))
    }
}
