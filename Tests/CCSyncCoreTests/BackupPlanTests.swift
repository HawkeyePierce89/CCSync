import XCTest
@testable import CCSyncCore

final class BackupPlanTests: XCTestCase {

    private let home = "/Users/alice"
    private var paths: KnownPaths { KnownPaths(home: home) }

    func testListCompositionOrderAndFlags() throws {
        let fs = InMemoryFileSystem()
        let alpha = "/Users/alice/git/Alpha"
        let bravo = "/Users/alice/git/Bravo"
        let ghost = "/Users/alice/git/Ghost"   // entry, no history directory
        let encAlpha = "-Users-alice-git-Alpha"
        let encBravo = "-Users-alice-git-Bravo"
        let encGhost = "-Users-alice-git-Ghost"
        let orphan = "-Users-alice-git-Orphan"  // directory, no entry

        // Deliberately unsorted key order in the JSON to prove the plan sorts.
        fs.seedFile("\(home)/.claude.json", """
        {"projects":{"\(bravo)":{"allowedTools":["Bash"]},"\(alpha)":{},"\(ghost)":{}}}
        """)
        fs.seedFile("\(home)/.claude/projects/\(encBravo)/s1.jsonl", "line")
        fs.seedFile("\(home)/.claude/projects/\(encAlpha)/s2.jsonl", "line")
        fs.seedFile("\(home)/.claude/projects/\(orphan)/s3.jsonl", "line")

        let plan = try BackupPlan(fileSystem: fs, paths: paths)

        XCTAssertEqual(plan.sourceUser, "alice")

        // Entries first by sorted path (Alpha, Bravo, Ghost), then orphans by
        // sorted encoded name.
        XCTAssertEqual(
            plan.projects.map(\.encodedName),
            [encAlpha, encBravo, encGhost, orphan]
        )

        let byName = Dictionary(uniqueKeysWithValues: plan.projects.map { ($0.encodedName, $0) })

        // Normal project carries its path and settings, and is complete.
        let bravoEntry = try XCTUnwrap(byName[encBravo])
        XCTAssertEqual(bravoEntry.path, bravo)
        XCTAssertEqual(bravoEntry.settings, JSONValue.object(["allowedTools": .array([.string("Bash")])]))
        XCTAssertFalse(bravoEntry.incomplete)
        XCTAssertNil(bravoEntry.incompleteReason)

        // Entry without a history directory is incomplete.
        let ghostEntry = try XCTUnwrap(byName[encGhost])
        XCTAssertEqual(ghostEntry.path, ghost)
        XCTAssertTrue(ghostEntry.incomplete)
        XCTAssertEqual(ghostEntry.incompleteReason, "no history directory on disk")

        // Orphan directory has no path/settings and its own reason.
        let orphanEntry = try XCTUnwrap(byName[orphan])
        XCTAssertEqual(orphanEntry.path, "")
        XCTAssertNil(orphanEntry.settings)
        XCTAssertTrue(orphanEntry.incomplete)
        XCTAssertEqual(orphanEntry.incompleteReason, "no entry in ~/.claude.json")
    }

    func testDoesNotReadSessionsOrScanHome() throws {
        let fs = InMemoryFileSystem()
        let project = "/Users/alice/git/App"
        let encoded = "-Users-alice-git-App"
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"\#(project)":{}}}"#)
        let sessionPath = "\(home)/.claude/projects/\(encoded)/44444444-4444-4444-4444-444444444444.jsonl"
        fs.seedFile(sessionPath, "transcript")

        let plan = try BackupPlan(fileSystem: fs, paths: paths)
        XCTAssertEqual(plan.projects.map(\.encodedName), [encoded])

        // The plan lists the projects root (to match dirs) but never reads a
        // session transcript, and never scans the home directory.
        XCTAssertFalse(fs.journal.contains(.readData(sessionPath)))
        XCTAssertFalse(fs.journal.contains(.listDirectory(home)))
    }

    func testEntryWithSymlinkedHistoryDirIsIncomplete() throws {
        let fs = InMemoryFileSystem()
        let project = "/Users/alice/git/App"
        let encoded = "-Users-alice-git-App"
        fs.seedFile("\(home)/.claude.json", #"{"projects":{"\#(project)":{}}}"#)
        // The `projects/<encoded>` name shows up in the listing but is a symlink —
        // the collector refuses to read sessions through it, so the plan must not
        // report the project as a complete backup.
        fs.seedSymlink("\(home)/.claude/projects/\(encoded)")

        let plan = try BackupPlan(fileSystem: fs, paths: paths)
        let entry = try XCTUnwrap(plan.projects.first { $0.encodedName == encoded })
        XCTAssertEqual(entry.path, project)
        XCTAssertTrue(entry.incomplete)
        XCTAssertEqual(entry.incompleteReason, "no history directory on disk")
        // It is claimed by the entry, so it does not also appear as an orphan.
        XCTAssertEqual(plan.projects.filter { $0.encodedName == encoded }.count, 1)
    }

    func testSymlinkedClaudeJSONIsTreatedAsAbsent() throws {
        let fs = InMemoryFileSystem()
        // A symlinked ~/.claude.json must not be followed; the plan sees no
        // projects and never reads the symlink target.
        fs.seedSymlink("\(home)/.claude.json")

        let plan = try BackupPlan(fileSystem: fs, paths: paths)
        XCTAssertTrue(plan.projects.isEmpty)
        XCTAssertFalse(fs.journal.contains(.readData("\(home)/.claude.json")))
    }
}
