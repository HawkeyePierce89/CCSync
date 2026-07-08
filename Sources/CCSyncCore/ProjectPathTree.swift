import Foundation

/// A collapsible, path-grouped view of the project selection, derived from the flat
/// `SelectionTree.Node` list. This is a **presentation-only** structure: it carries no
/// selection state whatsoever, so a renderer cannot bind a checkbox to stale data. All
/// selection reads/writes still go through the live `SelectionTree`
/// (`projectBinding`/`folderState`/`setFolder`) keyed by `encodedName`.
///
/// Derivation rules (locked, mirrored from the work plan):
///   - **Grouping:** each non-orphan `path` is split on `/` (leading empty dropped). The
///     final segment is the project leaf; the preceding segments are folders. A trie of
///     leaves is built from these segments.
///   - **Compaction:** a folder that is not itself a project and has exactly one child
///     folder merges its label with that child (joined by `/`), repeated. Compaction stops
///     at a leaf child, a multi-child folder, or a folder that is a project. Root folder
///     labels are prefixed with `/` to read as absolute (e.g. `/Users/alice`).
///   - **Project-is-also-a-prefix:** when a trie node is both a project and has
///     descendants, two sibling rows are emitted — the project as a leaf, then a folder of
///     the same name holding the descendants. The leaf sorts before its same-named folder.
///   - **Child ordering:** within a folder, children are sorted case-insensitively by
///     label, with a leaf-before-same-named-folder tiebreak.
///   - **Orphans (`path.isEmpty`):** collected into `orphans`, never placed in the
///     hierarchy.
public struct ProjectPathTree: Equatable, Sendable {

    /// One row in the tree: either a folder (grouping) or a project (leaf).
    public indirect enum Row: Equatable, Sendable, Identifiable {
        case folder(Folder)
        case project(Leaf)

        /// Stable identity: a folder is identified by its absolute `pathPrefix`, a
        /// project by its `encodedName`. The two namespaces never collide (slashes vs.
        /// dashes).
        public var id: String {
            switch self {
            case .folder(let f): return f.pathPrefix
            case .project(let l): return l.encodedName
            }
        }
    }

    /// A grouping node. Holds display fields plus the flat list of every leaf encoded
    /// name in its subtree (`descendantEncodedNames`) used to derive/route tri-state.
    public struct Folder: Equatable, Sendable {
        /// Display label (root folders prefixed with `/`, e.g. `/Users/alice`).
        public var label: String
        /// Absolute path prefix of this folder — also its stable row identity.
        public var pathPrefix: String
        /// Every leaf encoded name under this folder, sorted. Feeds
        /// `SelectionTree.folderState`/`setFolder` for tri-state.
        public var descendantEncodedNames: [String]
        /// Child rows, already sorted.
        public var children: [Row]

        public init(label: String, pathPrefix: String, descendantEncodedNames: [String], children: [Row]) {
            self.label = label
            self.pathPrefix = pathPrefix
            self.descendantEncodedNames = descendantEncodedNames
            self.children = children
        }
    }

    /// A project leaf. Display-only: it deliberately has **no** `isSelected` and does not
    /// carry the whole `Node`, so the single source of selection truth stays in
    /// `SelectionTree`.
    public struct Leaf: Equatable, Sendable {
        public var path: String
        public var encodedName: String
        public var incomplete: Bool
        public var incompleteReason: String?
        public var isSelectable: Bool
        /// Same wording as `SelectionTree.Node.incompleteSummary`, snapshotted here.
        public var incompleteSummary: String?

        public init(
            path: String,
            encodedName: String,
            incomplete: Bool,
            incompleteReason: String?,
            isSelectable: Bool,
            incompleteSummary: String?
        ) {
            self.path = path
            self.encodedName = encodedName
            self.incomplete = incomplete
            self.incompleteReason = incompleteReason
            self.isSelectable = isSelectable
            self.incompleteSummary = incompleteSummary
        }
    }

    /// Top-level rows, sorted.
    public var roots: [Row]
    /// Orphaned history directories (`path.isEmpty`), in input order.
    public var orphans: [Leaf]

    public init(nodes: [SelectionTree.Node]) {
        var orphanLeaves: [Leaf] = []
        let root = TrieNode()

        for node in nodes {
            if node.path.isEmpty {
                orphanLeaves.append(Self.makeLeaf(node))
                continue
            }
            let segs = Self.segments(node.path)
            if segs.isEmpty {
                // Degenerate path (e.g. "/") — carry it as an orphan rather than lose it.
                orphanLeaves.append(Self.makeLeaf(node))
                continue
            }
            var cur = root
            for seg in segs {
                if let next = cur.children[seg] {
                    cur = next
                } else {
                    let created = TrieNode()
                    cur.children[seg] = created
                    cur = created
                }
            }
            cur.leaf = node
        }

        var rootRows: [Row] = []
        for (seg, child) in root.children {
            rootRows.append(contentsOf: Self.rows(for: child, segment: seg, parentPath: "", isRoot: true))
        }
        rootRows.sort(by: Self.rowOrder)

        self.roots = rootRows
        self.orphans = orphanLeaves
    }

    // MARK: - Derivation

    private static func rows(for node: TrieNode, segment: String, parentPath: String, isRoot: Bool) -> [Row] {
        let isProject = node.leaf != nil
        let hasChildren = !node.children.isEmpty

        if isProject && !hasChildren {
            return [.project(makeLeaf(node.leaf!))]
        }
        if isProject && hasChildren {
            // Project-is-also-a-prefix: leaf first, then a same-named folder (no
            // top-label compaction) holding the descendants.
            let leafRow = Row.project(makeLeaf(node.leaf!))
            let folderRow = makeFolderRow(node, segment: segment, parentPath: parentPath, isRoot: isRoot, compactTopLabel: false)
            return [leafRow, folderRow]
        }
        // Pure folder — eligible for top-label compaction.
        return [makeFolderRow(node, segment: segment, parentPath: parentPath, isRoot: isRoot, compactTopLabel: true)]
    }

    private static func makeFolderRow(
        _ node: TrieNode,
        segment: String,
        parentPath: String,
        isRoot: Bool,
        compactTopLabel: Bool
    ) -> Row {
        var label = isRoot ? "/" + segment : segment
        var path = parentPath + "/" + segment
        var current = node

        if compactTopLabel {
            // Merge a chain of single-child folders. Stop at a project, a leaf child, or
            // a multi-child folder.
            while current.leaf == nil,
                  current.children.count == 1,
                  let (childSegment, child) = current.children.first,
                  child.leaf == nil,
                  !child.children.isEmpty {
                label += "/" + childSegment
                path += "/" + childSegment
                current = child
            }
        }

        var childRows: [Row] = []
        for (seg, child) in current.children {
            childRows.append(contentsOf: rows(for: child, segment: seg, parentPath: path, isRoot: false))
        }
        childRows.sort(by: rowOrder)

        let descendants = collectDescendants(current, includeSelf: false).sorted()
        return .folder(Folder(label: label, pathPrefix: path, descendantEncodedNames: descendants, children: childRows))
    }

    private static func collectDescendants(_ node: TrieNode, includeSelf: Bool) -> [String] {
        var out: [String] = []
        if includeSelf, let leaf = node.leaf {
            out.append(leaf.encodedName)
        }
        for (_, child) in node.children {
            out.append(contentsOf: collectDescendants(child, includeSelf: true))
        }
        return out
    }

    private static func makeLeaf(_ node: SelectionTree.Node) -> Leaf {
        Leaf(
            path: node.path,
            encodedName: node.encodedName,
            incomplete: node.incomplete,
            incompleteReason: node.incompleteReason,
            isSelectable: node.isSelectable,
            incompleteSummary: node.incompleteSummary
        )
    }

    // MARK: - Ordering

    private static func rowOrder(_ a: Row, _ b: Row) -> Bool {
        let ka = orderKey(a)
        let kb = orderKey(b)
        if ka.label != kb.label { return ka.label < kb.label }
        if ka.leafFirst != kb.leafFirst { return ka.leafFirst < kb.leafFirst }
        // Final deterministic tiebreak on the unique row id — siblings whose labels
        // differ only by case (distinct trie keys, both kept) would otherwise get an
        // unstable order from the dictionary-backed trie iteration.
        return a.id < b.id
    }

    /// Case-insensitive label key with a leaf-before-same-named-folder tiebreak. Root
    /// folder labels drop their leading `/` so a project sitting exactly at a root sorts
    /// against its same-named folder correctly.
    private static func orderKey(_ row: Row) -> (label: String, leafFirst: Int) {
        switch row {
        case .project(let leaf):
            return (lastSegment(leaf.path).lowercased(), 0)
        case .folder(let f):
            let base = f.label.hasPrefix("/") ? String(f.label.dropFirst()) : f.label
            return (base.lowercased(), 1)
        }
    }

    // MARK: - Path helpers

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func lastSegment(_ path: String) -> String {
        segments(path).last ?? path
    }
}

/// Mutable segment trie used only while deriving `ProjectPathTree`. A node is a project
/// when `leaf != nil` and a folder when it has children; it can be both.
private final class TrieNode {
    var children: [String: TrieNode] = [:]
    var leaf: SelectionTree.Node?
}
