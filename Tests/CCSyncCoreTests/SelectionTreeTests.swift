import XCTest
@testable import CCSyncCore

final class SelectionTreeTests: XCTestCase {

    private func samplePlan() -> RestorePlan {
        RestorePlan(
            sourceUser: "alice",
            sourceClaudeVersion: "1.2.3",
            projects: [
                ManifestProject(path: "/Users/alice/git/App", encodedName: "-Users-alice-git-App"),
                ManifestProject(path: "/Users/alice/git/Web", encodedName: "-Users-alice-git-Web"),
                ManifestProject(
                    path: "/Users/alice/git/Ghost",
                    encodedName: "-Users-alice-git-Ghost",
                    incomplete: true,
                    incompleteReason: "directory missing"
                ),
            ]
        )
    }

    // MARK: - Default build

    func testDefaultBuildSelectsGlobalMasterAndAllProjects() {
        let tree = SelectionTree(plan: samplePlan())
        XCTAssertTrue(tree.globalSelected)
        XCTAssertTrue(tree.projectsMasterSelected)
        XCTAssertEqual(tree.projects.count, 3)
        XCTAssertTrue(tree.projects.allSatisfy(\.isSelected))
        // Incompleteness flag is carried through for the View to surface.
        XCTAssertEqual(tree.projects.first { $0.encodedName.hasSuffix("Ghost") }?.incomplete, true)

        let selection = tree.resolvedSelection()
        XCTAssertTrue(selection.global)
        XCTAssertEqual(
            selection.projectEncodedNames,
            ["-Users-alice-git-App", "-Users-alice-git-Web", "-Users-alice-git-Ghost"]
        )
    }

    // MARK: - Backup plan builder

    private func sampleBackupPlan() -> BackupPlan {
        BackupPlan(
            sourceUser: "alice",
            projects: [
                ManifestProject(path: "/Users/alice/git/App", encodedName: "-Users-alice-git-App"),
                ManifestProject(path: "/Users/alice/git/Web", encodedName: "-Users-alice-git-Web"),
                ManifestProject(
                    path: "/Users/alice/git/Ghost",
                    encodedName: "-Users-alice-git-Ghost",
                    incomplete: true,
                    incompleteReason: "no history directory on disk"
                ),
            ]
        )
    }

    func testBackupPlanBuildSelectsGlobalMasterAndAllProjects() {
        let tree = SelectionTree(plan: sampleBackupPlan())
        XCTAssertTrue(tree.globalSelected)
        XCTAssertTrue(tree.projectsMasterSelected)
        XCTAssertEqual(tree.projects.count, 3)
        XCTAssertTrue(tree.projects.allSatisfy(\.isSelected))
        XCTAssertEqual(tree.projects.first { $0.encodedName.hasSuffix("Ghost") }?.incomplete, true)

        let selection = tree.resolvedSelection()
        XCTAssertTrue(selection.global)
        XCTAssertEqual(
            selection.projectEncodedNames,
            ["-Users-alice-git-App", "-Users-alice-git-Web", "-Users-alice-git-Ghost"]
        )
    }

    // MARK: - Projects master gates the whole set

    func testProjectsMasterOffYieldsOnlyGlobal() {
        var tree = SelectionTree(plan: samplePlan())
        tree.setProjectsMaster(false)

        let selection = tree.resolvedSelection()
        XCTAssertTrue(selection.global)
        XCTAssertTrue(selection.projectEncodedNames.isEmpty)
    }

    func testProjectsMasterOffIgnoresPerNodeState() {
        var tree = SelectionTree(plan: samplePlan())
        // Even with a node explicitly checked, the master gates everything off.
        tree.setProject(encodedName: "-Users-alice-git-App", true)
        tree.setProjectsMaster(false)
        XCTAssertTrue(tree.resolvedSelection().projectEncodedNames.isEmpty)
    }

    // MARK: - Per-project toggles

    func testDeselectingOneProjectExcludesItFromResolution() {
        var tree = SelectionTree(plan: samplePlan())
        tree.setProject(encodedName: "-Users-alice-git-Web", false)

        let selection = tree.resolvedSelection()
        XCTAssertEqual(
            selection.projectEncodedNames,
            ["-Users-alice-git-App", "-Users-alice-git-Ghost"]
        )
    }

    func testTogglingUnknownProjectIsNoOp() {
        var tree = SelectionTree(plan: samplePlan())
        tree.setProject(encodedName: "-Users-alice-git-DoesNotExist", false)
        XCTAssertEqual(tree.resolvedSelection().projectEncodedNames.count, 3)
    }

    // MARK: - Global toggle is independent

    func testGlobalCanBeToggledOffWhileProjectsRemain() {
        var tree = SelectionTree(plan: samplePlan())
        tree.setGlobal(false)

        let selection = tree.resolvedSelection()
        XCTAssertFalse(selection.global)
        XCTAssertEqual(selection.projectEncodedNames.count, 3)
    }

    // MARK: - JSONMerge (used by restore into ~/.claude.json)

    func testJSONMergePreservesUnknownKeysAndRecurses() {
        let base = JSONValue.object([
            "keep": .string("base"),
            "nested": .object(["a": .int(1), "b": .int(2)]),
        ])
        let incoming = JSONValue.object([
            "nested": .object(["b": .int(9), "c": .int(3)]),
            "new": .bool(true),
        ])
        let merged = JSONMerge.merge(base, incoming)
        XCTAssertEqual(merged, .object([
            "keep": .string("base"),
            "nested": .object(["a": .int(1), "b": .int(9), "c": .int(3)]),
            "new": .bool(true),
        ]))
    }

    func testJSONMergeIncomingWinsOnTypeMismatch() {
        let base = JSONValue.object(["x": .object(["deep": .int(1)])])
        let incoming = JSONValue.object(["x": .string("replaced")])
        XCTAssertEqual(JSONMerge.merge(base, incoming), .object(["x": .string("replaced")]))
    }
}
