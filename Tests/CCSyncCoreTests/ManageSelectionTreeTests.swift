import XCTest
@testable import CCSyncCore

final class ManageSelectionTreeTests: XCTestCase {

    /// A ManagePlan with a normal project and an orphan history directory,
    /// assembled directly (no filesystem) to exercise the builder in isolation.
    private func samplePlan() -> ManagePlan {
        let backup = BackupPlan(
            sourceUser: "alice",
            projects: [
                ManifestProject(path: "/Users/alice/git/App", encodedName: "-Users-alice-git-App"),
                ManifestProject(path: "/Users/alice/git/Web", encodedName: "-Users-alice-git-Web"),
                ManifestProject(
                    path: "",
                    encodedName: "-Users-alice-git-Orphan",
                    incomplete: true,
                    incompleteReason: "no entry in ~/.claude.json"
                ),
            ]
        )
        return ManagePlan(plan: backup, folderStatuses: [
            "-Users-alice-git-App": .deletable,
            "-Users-alice-git-Web": .deletable,
            "-Users-alice-git-Orphan": .orphan,
        ])
    }

    func testDefaultManageTreeIsEmptyAndAllSelectable() {
        let tree = SelectionTree(managePlan: samplePlan())

        XCTAssertFalse(tree.globalSelected)
        XCTAssertTrue(tree.projectsMasterSelected)
        XCTAssertEqual(tree.projects.count, 3)
        // Nothing selected by default...
        XCTAssertTrue(tree.projects.allSatisfy { !$0.isSelected })
        // ...but every node — including the orphan — is selectable.
        XCTAssertTrue(tree.projects.allSatisfy(\.isSelectable))

        let selection = tree.resolvedSelection()
        XCTAssertFalse(selection.global)
        XCTAssertTrue(selection.projectEncodedNames.isEmpty)
    }

    func testOrphanIsSelectableAndCanBeToggledOn() {
        var tree = SelectionTree(managePlan: samplePlan())
        tree.setProject(encodedName: "-Users-alice-git-Orphan", true)

        let orphan = tree.projects.first { $0.encodedName.hasSuffix("Orphan") }
        XCTAssertEqual(orphan?.isSelectable, true)
        XCTAssertEqual(orphan?.isSelected, true)
        XCTAssertTrue(tree.resolvedSelection().projectEncodedNames.contains("-Users-alice-git-Orphan"))
    }

    func testSetProjectAndSetFolderFlipNodesOn() {
        var tree = SelectionTree(managePlan: samplePlan())
        tree.setProject(encodedName: "-Users-alice-git-App", true)
        XCTAssertEqual(tree.resolvedSelection().projectEncodedNames, ["-Users-alice-git-App"])

        let gitNames = ["-Users-alice-git-App", "-Users-alice-git-Web"]
        tree.setFolder(descendantEncodedNames: gitNames, true)
        XCTAssertEqual(
            tree.resolvedSelection().projectEncodedNames,
            ["-Users-alice-git-App", "-Users-alice-git-Web"]
        )
    }

    func testFolderStateReflectsToggles() {
        var tree = SelectionTree(managePlan: samplePlan())
        let gitNames = ["-Users-alice-git-App", "-Users-alice-git-Web"]

        // Default Manage tree: everything off.
        XCTAssertEqual(tree.folderState(descendantEncodedNames: gitNames), .off)

        tree.setProject(encodedName: "-Users-alice-git-App", true)
        XCTAssertEqual(tree.folderState(descendantEncodedNames: gitNames), .mixed)

        tree.setProject(encodedName: "-Users-alice-git-Web", true)
        XCTAssertEqual(tree.folderState(descendantEncodedNames: gitNames), .on)
    }

    func testProjectPathTreeKeepsOrphansOutAndAllLeavesSelectable() {
        let tree = SelectionTree(managePlan: samplePlan())
        let grouped = ProjectPathTree(nodes: tree.projects)

        // The orphan lives in `orphans`, not the hierarchy.
        XCTAssertEqual(grouped.orphans.map(\.encodedName), ["-Users-alice-git-Orphan"])
        XCTAssertTrue(grouped.orphans.allSatisfy(\.isSelectable))

        // Every leaf in the hierarchy is selectable on the Manage side.
        func allLeaves(_ rows: [ProjectPathTree.Row]) -> [ProjectPathTree.Leaf] {
            rows.flatMap { row -> [ProjectPathTree.Leaf] in
                switch row {
                case .project(let leaf): return [leaf]
                case .folder(let folder): return allLeaves(folder.children)
                }
            }
        }
        XCTAssertTrue(allLeaves(grouped.roots).allSatisfy(\.isSelectable))
    }
}
