import XCTest
@testable import CCSyncCore

final class ProjectDataLocatorTests: XCTestCase {

    private let home = "/Users/alice"
    private var paths: KnownPaths { KnownPaths(home: home) }

    private let appEncoded = "-Users-alice-git-App"
    private let libEncoded = "-Users-alice-git-Lib"
    private let mainUUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let libUUID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private func locator(_ fs: InMemoryFileSystem) -> ProjectDataLocator {
        ProjectDataLocator(fileSystem: fs, paths: paths)
    }

    // Two projects, each with a session + linked artifacts. `App` additionally has
    // a sub-agent session so its `<main>-agent-xyz.json` todo is exercised.
    private func seedTwoProjects(_ fs: InMemoryFileSystem) {
        fs.seedFile("\(home)/.claude.json", #"""
        {"projects":{"/Users/alice/git/App":{},"/Users/alice/git/Lib":{}}}
        """#)

        let appDir = "\(home)/.claude/projects/\(appEncoded)"
        fs.seedFile("\(appDir)/\(mainUUID).jsonl", "app-main")
        fs.seedFile("\(appDir)/agent-xyz.jsonl", "app-subagent")
        fs.seedFile("\(home)/.claude/file-history/\(mainUUID)/edit.json", "fh")
        fs.seedFile("\(home)/.claude/session-env/\(mainUUID)/env.json", "env")
        fs.seedFile("\(home)/.claude/todos/\(mainUUID).json", "todo-main")
        fs.seedFile("\(home)/.claude/todos/\(mainUUID)-agent-xyz.json", "todo-agent")

        let libDir = "\(home)/.claude/projects/\(libEncoded)"
        fs.seedFile("\(libDir)/\(libUUID).jsonl", "lib-main")
        fs.seedFile("\(home)/.claude/file-history/\(libUUID)/edit.json", "lib-fh")
        fs.seedFile("\(home)/.claude/todos/\(libUUID).json", "lib-todo")
    }

    // MARK: - Discovery

    func testLocatorFindsHistoryDirAndLinkedArtifactsOnly() throws {
        let fs = InMemoryFileSystem()
        seedTwoProjects(fs)

        let result = try locator(fs).removablePaths(encodedName: appEncoded)

        // The history dir comes first (it covers every transcript in its subtree).
        XCTAssertEqual(result.first, paths.projectDir(encoded: appEncoded))

        XCTAssertEqual(Set(result), Set([
            paths.projectDir(encoded: appEncoded),
            paths.fileHistoryDir(uuid: mainUUID),
            paths.sessionEnvDir(uuid: mainUUID),
            KnownPaths.join(paths.todosDir, "\(mainUUID).json"),
            KnownPaths.join(paths.todosDir, "\(mainUUID)-agent-xyz.json"),
        ]))

        // Never another project's artifacts.
        XCTAssertFalse(result.contains(paths.projectDir(encoded: libEncoded)))
        XCTAssertFalse(result.contains(paths.fileHistoryDir(uuid: libUUID)))
        XCTAssertFalse(result.contains(KnownPaths.join(paths.todosDir, "\(libUUID).json")))
    }

    func testLocatorReturnsEmptyWhenNoHistoryOrArtifacts() throws {
        let fs = InMemoryFileSystem()
        // A project entry in ~/.claude.json but no history directory on disk.
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"/Users/alice/git/Ghost":{}}}"#)

        let result = try locator(fs).removablePaths(encodedName: "-Users-alice-git-Ghost")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - No-follow discipline

    func testLocatorSkipsSymlinkedProjectDir() throws {
        let fs = InMemoryFileSystem()
        let appDir = "\(home)/.claude/projects/\(appEncoded)"
        fs.seedFile("\(appDir)/\(mainUUID).jsonl", "leaked")
        fs.seedSymlink(appDir)

        let result = try locator(fs).removablePaths(encodedName: appEncoded)
        // A symlinked history root is never entered nor reported as removable.
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(fs.journal.contains(.listDirectory(appDir)))
    }

    func testLocatorSkipsSymlinkedArtifactRoot() throws {
        let fs = InMemoryFileSystem()
        let appDir = "\(home)/.claude/projects/\(appEncoded)"
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"/Users/alice/git/App":{}}}"#)
        fs.seedFile("\(appDir)/\(mainUUID).jsonl", "app-main")
        // The file-history dir for the session is a symlink — must be excluded.
        fs.seedSymlink("\(home)/.claude/file-history/\(mainUUID)")
        fs.seedFile("\(home)/.claude/session-env/\(mainUUID)/env.json", "env")

        let result = try locator(fs).removablePaths(encodedName: appEncoded)

        XCTAssertFalse(result.contains(paths.fileHistoryDir(uuid: mainUUID)))
        // The real (non-symlink) session-env dir is still found.
        XCTAssertTrue(result.contains(paths.sessionEnvDir(uuid: mainUUID)))
    }

    // MARK: - Journal: only known paths, never scans home

    func testLocatorTouchesOnlyKnownPaths() throws {
        let fs = InMemoryFileSystem()
        seedTwoProjects(fs)
        // Noise that must never be touched.
        fs.seedFile("\(home)/Documents/secret.txt", "nope")

        _ = try locator(fs).removablePaths(encodedName: appEncoded)

        let allowedPrefixes = [
            "\(home)/.claude/projects",
            "\(home)/.claude/file-history",
            "\(home)/.claude/session-env",
            "\(home)/.claude/todos",
        ]
        for access in fs.journal {
            let path = access.path
            let allowed = allowedPrefixes.contains { path == $0 || path.hasPrefix($0) }
            XCTAssertTrue(allowed, "locator touched unexpected path: \(path)")
        }
        XCTAssertFalse(fs.journal.contains(.listDirectory(home)))
        XCTAssertFalse(fs.journal.contains(.listDirectory("\(home)/.claude")))
    }

    // MARK: - Equivalence with BackupCollector

    func testLocatorPathSetMatchesBackupCollector() throws {
        let fs = InMemoryFileSystem()
        // A single project, no global config, no local settings — so every file the
        // collector reads (apart from ~/.claude.json itself) is a session artifact.
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"/Users/alice/git/App":{}}}"#)
        let appDir = "\(home)/.claude/projects/\(appEncoded)"
        fs.seedFile("\(appDir)/\(mainUUID).jsonl", "app-main")
        fs.seedFile("\(appDir)/agent-xyz.jsonl", "app-subagent")
        fs.seedFile("\(home)/.claude/file-history/\(mainUUID)/edit-1.json", "fh")
        fs.seedFile("\(home)/.claude/file-history/\(mainUUID)/nested/edit-2.json", "fh2")
        fs.seedFile("\(home)/.claude/session-env/\(mainUUID)/env.json", "env")
        fs.seedFile("\(home)/.claude/todos/\(mainUUID).json", "todo-main")
        fs.seedFile("\(home)/.claude/todos/\(mainUUID)-agent-xyz.json", "todo-agent")

        // What the collector actually reads for this project (global off; drop the
        // ~/.claude.json config read, leaving only session-artifact files).
        let selection = Selection(global: false, projectEncodedNames: [appEncoded])
        _ = try BackupCollector(fileSystem: fs, paths: paths).collect(selection: selection)
        let collectorReads = Set(fs.journal.compactMap { access -> String? in
            if case .readData(let p) = access { return p }
            return nil
        }).subtracting([paths.claudeJSON])

        // Every file covered by the locator's returned paths.
        let removable = try locator(fs).removablePaths(encodedName: appEncoded)
        var covered = Set<String>()
        for path in removable {
            for file in fs.allFiles.keys where file == path || file.hasPrefix(path + "/") {
                covered.insert(file)
            }
        }

        XCTAssertFalse(collectorReads.isEmpty)
        XCTAssertEqual(covered, collectorReads)
    }

    // MARK: - ~/.claude.json surgical key removal

    func testRemoveProjectRemovesExactlyOneKey() throws {
        let doc = try JSONValue(data: Data(#"""
        {"projects":{"/Users/alice/git/App":{"a":1},"/Users/alice/git/Lib":{"b":2}},"otherTop":true}
        """#.utf8))

        let (result, existed) = JSONMerge.removeProject("/Users/alice/git/App", from: doc)
        XCTAssertTrue(existed)

        let projects = try XCTUnwrap(result["projects"]?.objectValue)
        XCTAssertNil(projects["/Users/alice/git/App"])
        // Sibling project and unknown top-level key survive untouched.
        XCTAssertEqual(projects["/Users/alice/git/Lib"], .object(["b": .int(2)]))
        XCTAssertEqual(result["otherTop"], .bool(true))
    }

    func testRemoveProjectNoOpWhenPathAbsent() throws {
        let doc = try JSONValue(data: Data(#"""
        {"projects":{"/Users/alice/git/Lib":{"b":2}}}
        """#.utf8))

        let (result, existed) = JSONMerge.removeProject("/Users/alice/git/App", from: doc)
        XCTAssertFalse(existed)
        XCTAssertEqual(result, doc)
    }

    func testRemoveProjectNoOpWhenProjectsAbsent() throws {
        let doc = try JSONValue(data: Data(#"{"mcpServers":{"git":{}}}"#.utf8))

        let (result, existed) = JSONMerge.removeProject("/Users/alice/git/App", from: doc)
        XCTAssertFalse(existed)
        XCTAssertEqual(result, doc)
    }
}
