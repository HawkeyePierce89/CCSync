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
                    incompleteReason: "no entry in ~/.claude.json"
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

    // MARK: - Orphaned history directories are non-selectable on the backup side

    private func orphanBackupPlan() -> BackupPlan {
        BackupPlan(
            sourceUser: "alice",
            projects: [
                ManifestProject(path: "/Users/alice/git/App", encodedName: "-Users-alice-git-App"),
                ManifestProject(
                    path: "",
                    encodedName: "-Users-alice-git-Orphan",
                    incomplete: true,
                    incompleteReason: "no entry in ~/.claude.json"
                ),
            ]
        )
    }

    func testBackupPlanOrphanNodeIsNonSelectableAndOff() {
        let tree = SelectionTree(plan: orphanBackupPlan())

        let normal = tree.projects.first { $0.encodedName.hasSuffix("App") }
        XCTAssertEqual(normal?.isSelectable, true)
        XCTAssertEqual(normal?.isSelected, true)

        let orphan = tree.projects.first { $0.encodedName.hasSuffix("Orphan") }
        XCTAssertEqual(orphan?.isSelectable, false)
        XCTAssertEqual(orphan?.isSelected, false)
    }

    func testSetProjectIsNoOpForOrphanNode() {
        var tree = SelectionTree(plan: orphanBackupPlan())
        tree.setProject(encodedName: "-Users-alice-git-Orphan", true)

        let orphan = tree.projects.first { $0.encodedName.hasSuffix("Orphan") }
        // The node stays off — a non-selectable node cannot be turned on.
        XCTAssertEqual(orphan?.isSelected, false)
    }

    func testResolvedSelectionExcludesOrphanFromDefaultBackupTree() {
        let selection = SelectionTree(plan: orphanBackupPlan()).resolvedSelection()
        XCTAssertEqual(selection.projectEncodedNames, ["-Users-alice-git-App"])
        XCTAssertFalse(selection.projectEncodedNames.contains("-Users-alice-git-Orphan"))
    }

    func testRestorePlanOrphanProjectStaysSelectable() {
        // Regression: an orphan project from an archive is selectable and restorable.
        let plan = RestorePlan(
            sourceUser: "alice",
            sourceClaudeVersion: "1.2.3",
            projects: [
                ManifestProject(path: "/Users/alice/git/App", encodedName: "-Users-alice-git-App"),
                ManifestProject(
                    path: "",
                    encodedName: "-Users-alice-git-Orphan",
                    incomplete: true,
                    incompleteReason: "no entry in ~/.claude.json"
                ),
            ]
        )
        let tree = SelectionTree(plan: plan)

        let orphan = tree.projects.first { $0.encodedName.hasSuffix("Orphan") }
        XCTAssertEqual(orphan?.isSelectable, true)
        XCTAssertEqual(orphan?.isSelected, true)
        XCTAssertTrue(tree.resolvedSelection().projectEncodedNames.contains("-Users-alice-git-Orphan"))
    }

    // MARK: - Incomplete reason carried through and mapped to human wording

    func testIncompleteReasonCarriedThroughRestorePlanBuilder() {
        let tree = SelectionTree(plan: samplePlan())
        let ghost = tree.projects.first { $0.encodedName.hasSuffix("Ghost") }
        XCTAssertEqual(ghost?.incompleteReason, "no entry in ~/.claude.json")
    }

    func testIncompleteReasonCarriedThroughBackupPlanBuilder() {
        let tree = SelectionTree(plan: sampleBackupPlan())
        let ghost = tree.projects.first { $0.encodedName.hasSuffix("Ghost") }
        XCTAssertEqual(ghost?.incompleteReason, "no history directory on disk")
    }

    func testIncompleteSummaryMapsKnownReasonsViaPlanBuilders() {
        // RestorePlan Ghost: orphaned directory, no entry in ~/.claude.json.
        let restoreGhost = SelectionTree(plan: samplePlan())
            .projects.first { $0.encodedName.hasSuffix("Ghost") }
        XCTAssertEqual(restoreGhost?.incompleteSummary, "history only — no project settings")

        // BackupPlan Ghost: entry present but no history directory on disk.
        let backupGhost = SelectionTree(plan: sampleBackupPlan())
            .projects.first { $0.encodedName.hasSuffix("Ghost") }
        XCTAssertEqual(backupGhost?.incompleteSummary, "settings only — no session history")
    }

    func testIncompleteSummaryReturnsUnknownReasonAsIs() {
        let node = SelectionTree.Node(
            path: "/Users/alice/git/X",
            encodedName: "-Users-alice-git-X",
            incomplete: true,
            isSelected: true,
            incompleteReason: "some other reason"
        )
        XCTAssertEqual(node.incompleteSummary, "some other reason")
    }

    func testIncompleteSummaryIsNilForCompleteProject() {
        let complete = SelectionTree(plan: samplePlan())
            .projects.first { $0.encodedName.hasSuffix("App") }
        XCTAssertNil(complete?.incompleteSummary)
    }

    func testIncompleteSummaryFallsBackToGenericWhenReasonMissing() {
        let node = SelectionTree.Node(
            path: "/Users/alice/git/X",
            encodedName: "-Users-alice-git-X",
            incomplete: true,
            isSelected: true,
            incompleteReason: nil
        )
        // The orange label must never silently disappear while incomplete == true.
        XCTAssertEqual(node.incompleteSummary, "incomplete backup")
    }

    func testIncompleteSummaryFallsBackToGenericWhenReasonEmpty() {
        let node = SelectionTree.Node(
            path: "/Users/alice/git/X",
            encodedName: "-Users-alice-git-X",
            incomplete: true,
            isSelected: true,
            incompleteReason: ""
        )
        // An empty reason must not render as an empty orange label — the
        // `where !reason.isEmpty` guard falls through to the generic wording.
        XCTAssertEqual(node.incompleteSummary, "incomplete backup")
    }

    func testIncompleteSummaryIsNilForCompleteNodeEvenWithReason() {
        let node = SelectionTree.Node(
            path: "/Users/alice/git/X",
            encodedName: "-Users-alice-git-X",
            incomplete: false,
            isSelected: true,
            incompleteReason: "no history directory on disk"
        )
        // `incomplete == false` must win over any stale reason — no spurious label.
        XCTAssertNil(node.incompleteSummary)
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
