import XCTest
@testable import CCSyncCore

final class ManagePlanTests: XCTestCase {

    private let home = "/Users/alice"
    private var paths: KnownPaths { KnownPaths(home: home) }

    /// A fixture home covering all five folder-status cases:
    ///   - Normal: a real directory at the project path → deletable.
    ///   - Missing: an entry whose folder does not exist on disk → missing.
    ///   - Symlinked path: the project path is a symlink → symlink.
    ///   - Home path: the project path normalizes to the home directory → unsafePath.
    ///   - Orphan: a history directory with no entry (`path.isEmpty`) → orphan.
    private func mixedFixture() -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        let normal = "/Users/alice/git/Normal"
        let missing = "/Users/alice/git/Missing"
        let linked = "/Users/alice/git/Linked"
        let orphanEnc = "-Users-alice-git-Orphan"

        fs.seedFile("\(home)/.claude.json", """
        {"projects":{"\(normal)":{},"\(missing)":{},"\(linked)":{},"\(home)":{}}}
        """)
        // Give every entry a history directory so it is not filtered/incomplete on
        // that axis; folder status is about the project path, not the history dir.
        fs.seedFile("\(home)/.claude/projects/-Users-alice-git-Normal/s.jsonl", "x")
        fs.seedFile("\(home)/.claude/projects/-Users-alice-git-Missing/s.jsonl", "x")
        fs.seedFile("\(home)/.claude/projects/-Users-alice-git-Linked/s.jsonl", "x")
        fs.seedFile("\(home)/.claude/projects/-Users-alice/s.jsonl", "x")
        fs.seedFile("\(home)/.claude/projects/\(orphanEnc)/s.jsonl", "x")

        // On-disk project folders.
        fs.seedDirectory(normal)          // deletable
        // `missing` is intentionally absent.
        fs.seedSymlink(linked)            // symlink
        // `home` already exists as a directory; it is the unsafe path.
        return fs
    }

    func testFolderStatusDerivationAllCases() throws {
        let fs = mixedFixture()
        let plan = try ManagePlan(fileSystem: fs, paths: paths)

        XCTAssertEqual(plan.folderStatuses["-Users-alice-git-Normal"], .deletable)
        XCTAssertEqual(plan.folderStatuses["-Users-alice-git-Missing"], .missing)
        XCTAssertEqual(plan.folderStatuses["-Users-alice-git-Linked"], .symlink)
        XCTAssertEqual(plan.folderStatuses["-Users-alice"], .unsafePath)
        XCTAssertEqual(plan.folderStatuses["-Users-alice-git-Orphan"], .orphan)
    }

    func testRootPathIsUnsafe() {
        let fs = InMemoryFileSystem()
        XCTAssertEqual(
            ManagePlan.folderStatus(for: "/", fileSystem: fs, paths: paths),
            .unsafePath
        )
    }

    func testFolderCaptionWordingPerStatus() throws {
        let fs = mixedFixture()
        let plan = try ManagePlan(fileSystem: fs, paths: paths)

        XCTAssertNil(plan.folderCaption(for: "-Users-alice-git-Normal"))
        XCTAssertEqual(plan.folderCaption(for: "-Users-alice-git-Missing"), "folder already gone — Claude data only")
        XCTAssertEqual(plan.folderCaption(for: "-Users-alice-git-Linked"), "symlink — Claude data only")
        XCTAssertEqual(plan.folderCaption(for: "-Users-alice"), "unsafe path — Claude data only")
        // Orphans render their own incompleteSummary — no extra caption here.
        XCTAssertNil(plan.folderCaption(for: "-Users-alice-git-Orphan"))
        // Unknown name → nil.
        XCTAssertNil(plan.folderCaption(for: "-does-not-exist"))
    }

    func testDeletionSplitCountsForMixedSelection() throws {
        let fs = mixedFixture()
        let plan = try ManagePlan(fileSystem: fs, paths: paths)

        // Select one deletable + one missing + one symlink + the orphan.
        let selection = Selection(global: false, projectEncodedNames: [
            "-Users-alice-git-Normal",   // deletable → folder
            "-Users-alice-git-Missing",  // missing   → data only
            "-Users-alice-git-Linked",   // symlink   → data only
            "-Users-alice-git-Orphan",   // orphan    → data only
        ])
        let split = plan.deletionSplit(selection: selection)
        XCTAssertEqual(split.folders, 1)
        XCTAssertEqual(split.dataOnly, 3)
    }

    func testDeletionSplitEmptySelectionIsZero() throws {
        let fs = mixedFixture()
        let plan = try ManagePlan(fileSystem: fs, paths: paths)
        let split = plan.deletionSplit(selection: Selection(global: false, projectEncodedNames: []))
        XCTAssertEqual(split.folders, 0)
        XCTAssertEqual(split.dataOnly, 0)
    }

    func testDoesNotScanHomeAndProbesOnlyProjectPaths() throws {
        let fs = mixedFixture()
        _ = try ManagePlan(fileSystem: fs, paths: paths)

        // Invariant #1: home is never listed.
        XCTAssertFalse(fs.journal.contains(.listDirectory(home)))

        // Folder-status probing only ever touches the explicit project paths
        // (plus KnownPaths roots the underlying BackupPlan already reads).
        let probedForStatus = fs.journal.compactMap { access -> String? in
            switch access {
            case .isSymlink(let p), .isDirectory(let p):
                return p
            default:
                return nil
            }
        }
        // No status probe ever targets a session transcript or an arbitrary path.
        for p in probedForStatus {
            XCTAssertFalse(p.hasSuffix(".jsonl"), "unexpected status probe of \(p)")
        }
    }
}
