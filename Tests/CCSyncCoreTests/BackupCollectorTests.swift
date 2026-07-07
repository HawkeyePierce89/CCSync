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
