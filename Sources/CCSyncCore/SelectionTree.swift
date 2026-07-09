import Foundation

/// The resolved outcome of a `SelectionTree`: exactly which layers the restore
/// engine will apply. This is the flat value `RestoreService` consumes — all the
/// two-level toggle logic is collapsed here so the engine never re-implements it.
public struct Selection: Equatable, Sendable {
    /// Whether to restore the global config layer (`~/.claude` + global `mcpServers`).
    public var global: Bool
    /// Encoded `projects/` directory names selected for restore. Empty whenever the
    /// "Projects" master is off — the master gates the whole set.
    public var projectEncodedNames: Set<String>

    public init(global: Bool, projectEncodedNames: Set<String>) {
        self.global = global
        self.projectEncodedNames = projectEncodedNames
    }
}

/// The two-level restore selection model, built from a `RestorePlan` and mapped to
/// a flat `Selection`. This lives in Core (not the SwiftUI View) so the toggle
/// semantics are covered by `swift test`; the View is a dumb renderer over it.
///
/// Structure (per the plan):
///   - a standalone "Global config" toggle,
///   - a "Projects" master — when it is off, only the global layer applies and the
///     per-project toggles are inert,
///   - a per-project toggle for each project in the archive.
///
/// The default build has global on, the master on, and every project checked.
public struct SelectionTree: Equatable, Sendable {
    /// One selectable project row.
    public struct Node: Equatable, Sendable {
        /// Absolute project path from the archive (empty for an orphan directory).
        public var path: String
        /// Encoded `projects/` directory name — the stable identity of the node.
        public var encodedName: String
        /// Carried over from backup: the entry/directory pair was not both present.
        public var incomplete: Bool
        /// Raw reason string carried from the manifest, for the human-readable
        /// mapping in `incompleteSummary`. `nil` when the source did not record one.
        public var incompleteReason: String?
        /// Whether this project is checked for restore.
        public var isSelected: Bool
        /// Whether this node may be toggled by the user at all. `false` for an
        /// orphaned history directory on the backup side (`path.isEmpty` — no entry
        /// in `~/.claude.json`): such a node renders greyed out, stays off, and is
        /// excluded from the resolved selection. Always `true` on the restore side,
        /// so orphan projects from an archive remain selectable and restorable.
        public var isSelectable: Bool

        public init(
            path: String,
            encodedName: String,
            incomplete: Bool,
            isSelected: Bool,
            incompleteReason: String? = nil,
            isSelectable: Bool = true
        ) {
            self.path = path
            self.encodedName = encodedName
            self.incomplete = incomplete
            self.isSelected = isSelected
            self.incompleteReason = incompleteReason
            self.isSelectable = isSelectable
        }

        /// Human-readable one-line summary of the incompleteness, shared by the
        /// Backup and Restore screens (invariant #4 — one wording, in Core). The
        /// incomplete signal is never silently lost: while `incomplete == true`
        /// this is always non-`nil`.
        public var incompleteSummary: String? {
            guard incomplete else { return nil }
            switch incompleteReason {
            case "no history directory on disk":
                return "settings only — no session history"
            case "no entry in ~/.claude.json":
                return "history only — no project settings"
            case let reason? where !reason.isEmpty:
                return reason
            default:
                return "incomplete backup"
            }
        }
    }

    /// The standalone "Global config" toggle.
    public var globalSelected: Bool
    /// The "Projects" master toggle; when off, no project is restored.
    public var projectsMasterSelected: Bool
    /// One node per project in the archive, in archive order.
    public var projects: [Node]

    public init(
        globalSelected: Bool,
        projectsMasterSelected: Bool,
        projects: [Node]
    ) {
        self.globalSelected = globalSelected
        self.projectsMasterSelected = projectsMasterSelected
        self.projects = projects
    }

    /// Default-selection builder: global on, the Projects master on, and every
    /// project from the archive checked.
    public init(plan: RestorePlan) {
        self.init(
            globalSelected: true,
            projectsMasterSelected: true,
            projects: plan.projects.map {
                Node(path: $0.path, encodedName: $0.encodedName, incomplete: $0.incomplete, isSelected: true, incompleteReason: $0.incompleteReason)
            }
        )
    }

    /// Default-selection builder for the backup side: global on, the Projects
    /// master on, and every project from the local inventory checked. Mirrors the
    /// `RestorePlan` builder so GUI and CLI present an identical two-level tree,
    /// except that an orphaned history directory (`path.isEmpty` — no entry in
    /// `~/.claude.json`) is non-selectable and left off by default, so the default
    /// backup tree excludes it from the archive.
    public init(plan: BackupPlan) {
        self.init(
            globalSelected: true,
            projectsMasterSelected: true,
            projects: plan.projects.map {
                let isOrphan = $0.path.isEmpty
                return Node(
                    path: $0.path,
                    encodedName: $0.encodedName,
                    incomplete: $0.incomplete,
                    isSelected: !isOrphan,
                    incompleteReason: $0.incompleteReason,
                    isSelectable: !isOrphan
                )
            }
        )
    }

    /// Manage-tab builder: the inverse of `init(plan: BackupPlan)`. Nothing global
    /// is deletable, so `globalSelected` is `false`; the "Projects" master is on so
    /// leaves are live/enabled; every project node is default-off but selectable —
    /// including orphans (`path.isEmpty`), which are deletable Claude data on the
    /// Manage side even though they are non-selectable for backup. A fresh Manage
    /// tree therefore resolves to an empty project set until the user picks rows.
    public init(managePlan: ManagePlan) {
        self.init(
            globalSelected: false,
            projectsMasterSelected: true,
            projects: managePlan.plan.projects.map {
                Node(
                    path: $0.path,
                    encodedName: $0.encodedName,
                    incomplete: $0.incomplete,
                    isSelected: false,
                    incompleteReason: $0.incompleteReason,
                    isSelectable: true
                )
            }
        )
    }

    // MARK: - Resolution

    /// Collapse the tree into the flat `Selection` the restore engine consumes.
    /// With the master off the project set is empty regardless of per-node state.
    public func resolvedSelection() -> Selection {
        let names: Set<String>
        if projectsMasterSelected {
            names = Set(projects.filter(\.isSelected).map(\.encodedName))
        } else {
            names = []
        }
        return Selection(global: globalSelected, projectEncodedNames: names)
    }

    // MARK: - Mutation helpers

    public mutating func setGlobal(_ on: Bool) {
        globalSelected = on
    }

    public mutating func setProjectsMaster(_ on: Bool) {
        projectsMasterSelected = on
    }

    /// Toggle a single project by its encoded name; no-op if unknown or if the
    /// node is non-selectable (an orphaned history directory on the backup side).
    public mutating func setProject(encodedName: String, _ on: Bool) {
        guard let index = projects.firstIndex(where: { $0.encodedName == encodedName }) else { return }
        guard projects[index].isSelectable else { return }
        projects[index].isSelected = on
    }
}

/// The tri-state of a folder checkbox in the grouped project tree, derived from the
/// selection state of the leaves in its subtree.
public enum FolderCheckState: Equatable, Sendable {
    /// Every (known) descendant leaf is selected.
    case on
    /// No (known) descendant leaf is selected.
    case off
    /// Some — but not all — descendant leaves are selected.
    case mixed
}

extension SelectionTree {
    /// Derive a folder's tri-state from the selection of its descendant leaves.
    ///
    /// Encoded names not present in the tree are skipped, not treated as "off" — the
    /// derived tree may in theory lag the live `SelectionTree`. A list that names only
    /// unknown leaves therefore derives `.off` (no known descendant is selected).
    public func folderState(descendantEncodedNames: [String]) -> FolderCheckState {
        let known = descendantEncodedNames.compactMap { name in
            projects.first { $0.encodedName == name }
        }
        guard !known.isEmpty else { return .off }
        let selectedCount = known.filter(\.isSelected).count
        if selectedCount == 0 { return .off }
        if selectedCount == known.count { return .on }
        return .mixed
    }

    /// Cascade a folder toggle to every descendant leaf, routing each write through
    /// `setProject` so non-selectable leaves are never flipped, unknown names no-op,
    /// and a master-off tree still resolves to an empty project set.
    public mutating func setFolder(descendantEncodedNames: [String], _ on: Bool) {
        for name in descendantEncodedNames {
            setProject(encodedName: name, on)
        }
    }
}
