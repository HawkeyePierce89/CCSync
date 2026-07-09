import XCTest
@testable import CCSyncCore

final class ProjectPathTreeTests: XCTestCase {

    private func node(
        _ path: String,
        _ encodedName: String,
        incomplete: Bool = false,
        incompleteReason: String? = nil,
        isSelectable: Bool = true
    ) -> SelectionTree.Node {
        // `isSelected` is deliberately varied here to prove the derived tree ignores
        // it — ProjectPathTree carries no selection state.
        SelectionTree.Node(
            path: path,
            encodedName: encodedName,
            incomplete: incomplete,
            isSelected: false,
            incompleteReason: incompleteReason,
            isSelectable: isSelectable
        )
    }

    private func folder(_ row: ProjectPathTree.Row?, file: StaticString = #filePath, line: UInt = #line) -> ProjectPathTree.Folder {
        guard case .folder(let f)? = row else {
            XCTFail("expected a folder row, got \(String(describing: row))", file: file, line: line)
            return ProjectPathTree.Folder(label: "", pathPrefix: "", descendantEncodedNames: [], children: [])
        }
        return f
    }

    private func leaf(_ row: ProjectPathTree.Row?, file: StaticString = #filePath, line: UInt = #line) -> ProjectPathTree.Leaf {
        guard case .project(let l)? = row else {
            XCTFail("expected a project row, got \(String(describing: row))", file: file, line: line)
            return ProjectPathTree.Leaf(path: "", encodedName: "", name: "", incomplete: false, incompleteReason: nil, isSelectable: true, incompleteSummary: nil)
        }
        return l
    }

    // MARK: - Acceptance-1 shape

    func testGroupsUnderSingleCompactedRootWithTwoFolders() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/git/x", "-Users-a-git-x"),
            node("/Users/a/git/y", "-Users-a-git-y"),
            node("/Users/a/work/z", "-Users-a-work-z"),
        ])

        XCTAssertTrue(tree.orphans.isEmpty)
        XCTAssertEqual(tree.roots.count, 1)

        let root = folder(tree.roots.first)
        XCTAssertEqual(root.label, "/Users/a")
        XCTAssertEqual(root.pathPrefix, "/Users/a")
        XCTAssertEqual(root.children.count, 2)

        let git = folder(root.children.first)
        XCTAssertEqual(git.label, "git")
        XCTAssertEqual(git.pathPrefix, "/Users/a/git")
        XCTAssertEqual(git.children.count, 2)
        XCTAssertEqual(leaf(git.children[0]).encodedName, "-Users-a-git-x")
        XCTAssertEqual(leaf(git.children[1]).encodedName, "-Users-a-git-y")

        let work = folder(root.children.last)
        XCTAssertEqual(work.label, "work")
        XCTAssertEqual(work.children.count, 1)
        XCTAssertEqual(leaf(work.children[0]).encodedName, "-Users-a-work-z")
    }

    // MARK: - Single-child compaction of a lone project chain

    func testCompactsLoneProjectChainIntoOneRootFolder() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/git/deep/App", "-Users-a-git-deep-App"),
        ])

        XCTAssertEqual(tree.roots.count, 1)
        let root = folder(tree.roots.first)
        XCTAssertEqual(root.label, "/Users/a/git/deep")
        XCTAssertEqual(root.pathPrefix, "/Users/a/git/deep")
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(leaf(root.children[0]).encodedName, "-Users-a-git-deep-App")
    }

    // MARK: - Project-is-also-a-prefix

    func testProjectThatIsAlsoAPrefixEmitsLeafBeforeSameNamedFolder() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/git/App", "-Users-a-git-App"),
            node("/Users/a/git/App/Sub", "-Users-a-git-App-Sub"),
        ])

        // Compacts down to /Users/a/git, which holds the split App node.
        let gitFolder = folder(tree.roots.first)
        XCTAssertEqual(gitFolder.label, "/Users/a/git")
        XCTAssertEqual(gitFolder.children.count, 2)

        // Leaf App sorts before its same-named sibling folder.
        let appLeaf = leaf(gitFolder.children[0])
        XCTAssertEqual(appLeaf.encodedName, "-Users-a-git-App")

        let appFolder = folder(gitFolder.children[1])
        XCTAssertEqual(appFolder.label, "App")
        XCTAssertEqual(appFolder.pathPrefix, "/Users/a/git/App")
        XCTAssertEqual(appFolder.children.count, 1)
        XCTAssertEqual(leaf(appFolder.children[0]).encodedName, "-Users-a-git-App-Sub")

        // The folder-half carries only the descendants (not the project's own name).
        XCTAssertEqual(appFolder.descendantEncodedNames, ["-Users-a-git-App-Sub"])
        // The enclosing folder carries both the project and its descendant.
        XCTAssertEqual(gitFolder.descendantEncodedNames, ["-Users-a-git-App", "-Users-a-git-App-Sub"])
    }

    // MARK: - Child ordering (case-insensitive by label)

    func testChildrenSortedCaseInsensitivelyByLabel() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/Zebra", "-Users-a-Zebra"),
            node("/Users/a/apple", "-Users-a-apple"),
            node("/Users/a/Mango", "-Users-a-Mango"),
        ])

        let root = folder(tree.roots.first)
        XCTAssertEqual(root.label, "/Users/a")
        XCTAssertEqual(root.children.map { leaf($0).encodedName }, [
            "-Users-a-apple",
            "-Users-a-Mango",
            "-Users-a-Zebra",
        ])
    }

    // MARK: - Orphan placement

    func testOrphansLandInOrphansNotRoots() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/git/App", "-Users-a-git-App"),
            node("", "-Users-a-git-Orphan", incomplete: true, incompleteReason: "no entry in ~/.claude.json"),
        ])

        XCTAssertEqual(tree.orphans.count, 1)
        let orphan = tree.orphans[0]
        XCTAssertEqual(orphan.encodedName, "-Users-a-git-Orphan")
        XCTAssertEqual(orphan.incompleteSummary, "history only — no project settings")

        // The orphan never enters the hierarchy.
        let root = folder(tree.roots.first)
        XCTAssertFalse(root.descendantEncodedNames.contains("-Users-a-git-Orphan"))
        XCTAssertEqual(root.descendantEncodedNames, ["-Users-a-git-App"])
    }

    // MARK: - descendantEncodedNames completeness

    func testDescendantEncodedNamesCoverWholeSubtree() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/git/x", "-Users-a-git-x"),
            node("/Users/a/git/y", "-Users-a-git-y"),
            node("/Users/a/work/z", "-Users-a-work-z"),
        ])

        let root = folder(tree.roots.first)
        XCTAssertEqual(root.descendantEncodedNames, [
            "-Users-a-git-x",
            "-Users-a-git-y",
            "-Users-a-work-z",
        ])
        XCTAssertEqual(folder(root.children.first).descendantEncodedNames, [
            "-Users-a-git-x",
            "-Users-a-git-y",
        ])
        XCTAssertEqual(folder(root.children.last).descendantEncodedNames, [
            "-Users-a-work-z",
        ])
    }

    // MARK: - Leaf carries display fields verbatim, no selection state

    func testLeafCarriesDisplayFieldsVerbatim() {
        let tree = ProjectPathTree(nodes: [
            node(
                "/Users/a/git/Ghost",
                "-Users-a-git-Ghost",
                incomplete: true,
                incompleteReason: "no history directory on disk",
                isSelectable: false
            ),
        ])

        let root = folder(tree.roots.first)
        let ghost = leaf(root.children.first)
        XCTAssertEqual(ghost.path, "/Users/a/git/Ghost")
        XCTAssertEqual(ghost.encodedName, "-Users-a-git-Ghost")
        XCTAssertTrue(ghost.incomplete)
        XCTAssertEqual(ghost.incompleteReason, "no history directory on disk")
        XCTAssertFalse(ghost.isSelectable)
        // Same wording as SelectionTree.Node.incompleteSummary.
        XCTAssertEqual(ghost.incompleteSummary, "settings only — no session history")
    }

    // MARK: - Leaf.name (last path segment display label)

    func testLeafNameIsLastPathSegment() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/git/bocore", "-Users-a-git-bocore"),
        ])
        let root = folder(tree.roots.first)
        XCTAssertEqual(leaf(root.children.first).name, "bocore")
    }

    func testProjectThatIsAlsoAPrefixLeafKeepsItsOwnSegmentAsName() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/git/App", "-Users-a-git-App"),
            node("/Users/a/git/App/Sub", "-Users-a-git-App-Sub"),
        ])
        let gitFolder = folder(tree.roots.first)
        // The project leaf half keeps its own final segment.
        XCTAssertEqual(leaf(gitFolder.children[0]).name, "App")
        // And its descendant leaf under the same-named folder keeps its own.
        let appFolder = folder(gitFolder.children[1])
        XCTAssertEqual(leaf(appFolder.children[0]).name, "Sub")
    }

    func testOrphanLeafNameIsEmpty() {
        let tree = ProjectPathTree(nodes: [
            node("", "-Users-a-git-Orphan", incomplete: true, incompleteReason: "no entry in ~/.claude.json"),
        ])
        XCTAssertEqual(tree.orphans.count, 1)
        XCTAssertEqual(tree.orphans[0].name, "")
    }

    // MARK: - Row identity

    func testRowIdentityUsesPathPrefixAndEncodedName() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/git/App", "-Users-a-git-App"),
        ])
        let root = folder(tree.roots.first)
        XCTAssertEqual(tree.roots.first?.id, root.pathPrefix)
        XCTAssertEqual(root.children.first?.id, "-Users-a-git-App")
    }

    // MARK: - Multiple top-level roots

    func testMultipleTopLevelRootsAreSortedCaseInsensitively() {
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/App", "-Users-a-App"),
            node("/opt/b/App", "-opt-b-App"),
        ])

        XCTAssertEqual(tree.roots.count, 2)
        // "opt/b" sorts before "Users/a" case-insensitively.
        XCTAssertEqual(folder(tree.roots[0]).label, "/opt/b")
        XCTAssertEqual(folder(tree.roots[1]).label, "/Users/a")
    }

    // MARK: - Root-level project-is-also-a-prefix

    func testRootLevelProjectThatIsAlsoAPrefixEmitsLeafBeforeSameNamedFolder() {
        let tree = ProjectPathTree(nodes: [
            node("/App", "-App"),
            node("/App/Sub", "-App-Sub"),
        ])

        XCTAssertEqual(tree.roots.count, 2)
        // Leaf /App sorts before its same-named root folder.
        XCTAssertEqual(leaf(tree.roots[0]).encodedName, "-App")
        let appFolder = folder(tree.roots[1])
        XCTAssertEqual(appFolder.label, "/App")
        XCTAssertEqual(appFolder.pathPrefix, "/App")
        XCTAssertEqual(appFolder.descendantEncodedNames, ["-App-Sub"])
    }

    // MARK: - Degenerate path fallback

    func testDegenerateSlashPathLandsInOrphans() {
        let tree = ProjectPathTree(nodes: [
            node("/", "-slash"),
            node("/Users/a/App", "-Users-a-App"),
        ])

        XCTAssertEqual(tree.orphans.map(\.encodedName), ["-slash"])
        // A degenerate "/" path is an orphan, so its `name` must be empty (the renderer
        // falls back to `encodedName`) — not the raw "/" segment.
        XCTAssertEqual(tree.orphans.first?.name, "")
        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertEqual(folder(tree.roots.first).label, "/Users/a")
    }

    // MARK: - Empty input

    func testEmptyInputProducesEmptyTree() {
        let tree = ProjectPathTree(nodes: [])
        XCTAssertTrue(tree.roots.isEmpty)
        XCTAssertTrue(tree.orphans.isEmpty)
    }

    // MARK: - Duplicate non-empty paths

    func testDuplicatePathsEachGetTheirOwnLeafAndStayInFolderDescendants() {
        // A crafted/older archive can carry two projects with the same non-empty path but
        // distinct encoded names. Neither may be silently hidden from the tree while
        // SelectionTree keeps both selectable.
        let tree = ProjectPathTree(nodes: [
            node("/Users/a/git/App", "-Users-a-git-App"),
            node("/Users/a/git/App", "-Users-a-git-App-dup"),
        ])

        // Compacts to /Users/a/git holding both same-path leaves (no children on either).
        let gitFolder = folder(tree.roots.first)
        XCTAssertEqual(gitFolder.label, "/Users/a/git")
        XCTAssertEqual(gitFolder.children.count, 2)
        XCTAssertEqual(gitFolder.children.map { leaf($0).encodedName }.sorted(), [
            "-Users-a-git-App",
            "-Users-a-git-App-dup",
        ])
        // Both encoded names remain reachable through the folder tri-state helpers.
        XCTAssertEqual(gitFolder.descendantEncodedNames, [
            "-Users-a-git-App",
            "-Users-a-git-App-dup",
        ])
    }

    // MARK: - Orphan input-order preservation

    func testMultipleOrphansPreserveInputOrder() {
        let tree = ProjectPathTree(nodes: [
            node("", "-orphan-b"),
            node("", "-orphan-a"),
        ])

        XCTAssertTrue(tree.roots.isEmpty)
        XCTAssertEqual(tree.orphans.map(\.encodedName), ["-orphan-b", "-orphan-a"])
    }
}
