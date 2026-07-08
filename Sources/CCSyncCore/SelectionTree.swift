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

        public init(
            path: String,
            encodedName: String,
            incomplete: Bool,
            isSelected: Bool,
            incompleteReason: String? = nil
        ) {
            self.path = path
            self.encodedName = encodedName
            self.incomplete = incomplete
            self.isSelected = isSelected
            self.incompleteReason = incompleteReason
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
    /// `RestorePlan` builder so GUI and CLI present an identical two-level tree.
    public init(plan: BackupPlan) {
        self.init(
            globalSelected: true,
            projectsMasterSelected: true,
            projects: plan.projects.map {
                Node(path: $0.path, encodedName: $0.encodedName, incomplete: $0.incomplete, isSelected: true, incompleteReason: $0.incompleteReason)
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

    /// Toggle a single project by its encoded name; no-op if unknown.
    public mutating func setProject(encodedName: String, _ on: Bool) {
        guard let index = projects.firstIndex(where: { $0.encodedName == encodedName }) else { return }
        projects[index].isSelected = on
    }
}
