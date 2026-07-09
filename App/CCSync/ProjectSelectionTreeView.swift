import SwiftUI
import CCSyncCore

/// Shared renderer for the grouped, collapsible project selection used by the Backup,
/// Restore, and Manage screens. It is a **dumb renderer** over a `ProjectPathTree`
/// (derived, selection-free): every checkbox reads and writes the live `SelectionTree`
/// through the injected closures, never a value snapshotted in the tree. Inputs are plain
/// values + closures so all three view models reuse it without a shared protocol.
///
/// Rendering is a **flattened, guide-lined, leading-aligned** tree rather than nested
/// `DisclosureGroup`s. `tree.roots` is walked (respecting the local `expanded` map, read as
/// `map[id] ?? true`, so ids that only appear later — e.g. after Refresh — still start
/// expanded) into an ordered list of visible rows, each keyed on its underlying
/// `ProjectPathTree.Row.id` (folder `pathPrefix` / project `encodedName`), never on an array
/// offset, so a collapse/expand never recycles a row onto a different node. Every row is a
/// single full-width `HStack`: classic tree guide lines (one fixed-width cell per depth
/// level, drawn in `.separatorColor`) → a chevron `Button` for folders (a distinctly-named,
/// stateful expand/collapse control, kept separate from the checkbox) → the selection
/// control (folder tri-state `Button` / leaf `Toggle`) → the label. Folder headers show the
/// compacted, middle-truncated `label`; leaves show only `leaf.name` (the last path segment),
/// leading-aligned, with the full `path` as a `.help` tooltip, plus the `incompleteSummary`
/// caption and (Manage-only) `leafCaption`, greyed + disabled when non-selectable. Orphans
/// render after the tree in a "History only — no project entry" section using the same live
/// leaf row, so they stay toggleable on Restore and greyed on Backup exactly as before.
struct ProjectSelectionTreeView: View {
    let tree: ProjectPathTree
    let isRunning: Bool
    let projectsMasterOn: Bool
    let folderState: ([String]) -> FolderCheckState
    let toggleFolder: ([String], Bool) -> Void
    let projectBinding: (String) -> Binding<Bool>
    /// Optional extra caption per leaf, keyed by encoded name — the Manage screen's
    /// Core folder caption ("folder already gone — Claude data only" etc.). Defaults
    /// to none so Backup and Restore reuse the view unchanged.
    var leafCaption: (String) -> String? = { _ in nil }

    /// Expansion state keyed by row id. Absent id ⇒ expanded (`?? true`).
    @State private var expanded: [String: Bool] = [:]

    /// One entry per visible (expanded-into) row, in render order.
    private struct RenderRow: Identifiable {
        let row: ProjectPathTree.Row
        /// Whether this row is the last among its immediate siblings (corner vs. T-junction).
        let isLastSibling: Bool
        /// Per-ancestor continuation flags: `prefixLines[i]` is `true` when the ancestor at
        /// depth `i` still has a following sibling, so a vertical guide line passes through
        /// that column. Length == nesting depth; the final entry only guides deeper descendants.
        let prefixLines: [Bool]
        /// Nesting depth (0 = root), derived from `prefixLines` so the two can't drift.
        var depth: Int { prefixLines.count }
        /// Forwarded verbatim from the underlying node so the `ForEach` never keys on offsets.
        var id: String { row.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // spacing 0 so the vertical guide lines connect flush across rows.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(flattenedRows) { render in
                    rowView(render)
                }
            }

            if !tree.orphans.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("History only — no project entry")
                        .font(.subheadline).bold()
                        .foregroundStyle(.secondary)
                    ForEach(tree.orphans, id: \.encodedName) { leaf in
                        LeafRow(
                            leaf: leaf,
                            isRunning: isRunning,
                            projectsMasterOn: projectsMasterOn,
                            isOn: projectBinding(leaf.encodedName),
                            caption: leafCaption(leaf.encodedName)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Flatten

    /// Walk the tree into visible rows, following the `expanded` map. `prefix` accumulates,
    /// for each ancestor level, whether that ancestor has a following sibling (its vertical
    /// guide line should keep going past this row).
    private var flattenedRows: [RenderRow] {
        var out: [RenderRow] = []
        func walk(_ rows: [ProjectPathTree.Row], prefix: [Bool]) {
            for (index, row) in rows.enumerated() {
                let isLast = index == rows.count - 1
                out.append(RenderRow(row: row, isLastSibling: isLast, prefixLines: prefix))
                if case .folder(let folder) = row, isExpanded(folder.pathPrefix) {
                    walk(folder.children, prefix: prefix + [!isLast])
                }
            }
        }
        walk(tree.roots, prefix: [])
        return out
    }

    private func isExpanded(_ id: String) -> Bool { expanded[id] ?? true }

    // MARK: - Row

    @ViewBuilder
    private func rowView(_ render: RenderRow) -> some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(guideKinds(render).enumerated()), id: \.offset) { _, kind in
                GuideCell(kind: kind)
            }
            // Chevron + selection control + label share one padded HStack so the guide
            // cells (outside the padding) span the row's full height and stay connected.
            HStack(alignment: .top, spacing: 4) {
                chevronSlot(render)
                switch render.row {
                case .folder(let folder):
                    folderHeader(folder)
                case .project(let leaf):
                    LeafRow(
                        leaf: leaf,
                        isRunning: isRunning,
                        projectsMasterOn: projectsMasterOn,
                        isOn: projectBinding(leaf.encodedName),
                        caption: leafCaption(leaf.encodedName)
                    )
                }
            }
            .padding(.vertical, GuideMetrics.rowPadding)
        }
    }

    /// The guide-line kinds for a row's depth columns: passing/empty for ancestor columns,
    /// a corner or T-junction for the final connector column.
    private func guideKinds(_ render: RenderRow) -> [GuideCell.Kind] {
        guard render.depth > 0 else { return [] }
        var kinds: [GuideCell.Kind] = []
        for col in 0..<render.depth {
            if col < render.depth - 1 {
                kinds.append(render.prefixLines[col] ? .vertical : .empty)
            } else {
                kinds.append(render.isLastSibling ? .corner : .teeJunction)
            }
        }
        return kinds
    }

    /// A folder's expand/collapse chevron (a real focusable `Button`, distinctly named so
    /// VoiceOver never announces it identically to the adjacent tri-state checkbox), or an
    /// equal-width spacer for leaves so their selection controls line up under folders'.
    @ViewBuilder
    private func chevronSlot(_ render: RenderRow) -> some View {
        if case .folder(let folder) = render.row {
            let isExp = isExpanded(folder.pathPrefix)
            Button {
                expanded[folder.pathPrefix] = !isExp
            } label: {
                Image(systemName: isExp ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: GuideMetrics.chevronWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExp ? "\(folder.label), collapse" : "\(folder.label), expand")
        } else {
            Color.clear.frame(width: GuideMetrics.chevronWidth, height: 1)
        }
    }

    @ViewBuilder
    private func folderHeader(_ folder: ProjectPathTree.Folder) -> some View {
        let state = folderState(folder.descendantEncodedNames)
        let disabled = isRunning || !projectsMasterOn
        // A real Button (not an Image + onTapGesture) so the tri-state control is
        // keyboard-focusable, carries the button trait, and honours `.disabled` for
        // VoiceOver. Its accessibility value announces on/off/mixed. `.plain` keeps the
        // borderless checkbox+label look; the separate chevron drives expand/collapse.
        Button {
            // Tap semantics: on → off, off/mixed → on.
            toggleFolder(folder.descendantEncodedNames, state != .on)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: checkboxImage(state))
                    .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
                Text(folder.label)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(disabled ? .secondary : .primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(folder.label)
        .accessibilityValue(accessibilityValue(state))
    }

    private func checkboxImage(_ state: FolderCheckState) -> String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        }
    }

    private func accessibilityValue(_ state: FolderCheckState) -> String {
        switch state {
        case .on: return "checked"
        case .off: return "unchecked"
        case .mixed: return "mixed"
        }
    }
}

/// Layout constants shared by the flattened row and its guide cells.
private enum GuideMetrics {
    /// Width of a single depth/guide column (uniform indent step).
    static let indent: CGFloat = 18
    /// Chevron column width (also the leaf spacer width, for aligned selection controls).
    static let chevronWidth: CGFloat = 16
    /// Vertical padding inside the content HStack; the guide cells span past it.
    static let rowPadding: CGFloat = 4
    /// Vertical offset of the connector's horizontal tick — lines up with the checkbox on
    /// the row's first text line (top padding + roughly half a control's height).
    static let connectorY: CGFloat = 12
}

/// One guide-line column. `.vertical` passes a continuing ancestor line straight through;
/// `.teeJunction` (├) and `.corner` (└) draw this row's own connector into the content;
/// `.empty` is a blank indent cell. Drawn in `.separatorColor` to read as a classic
/// tree-view guide.
private struct GuideCell: View {
    enum Kind { case empty, vertical, teeJunction, corner }
    let kind: Kind

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let midX = geo.size.width / 2
                let tickY = GuideMetrics.connectorY
                switch kind {
                case .empty:
                    break
                case .vertical:
                    path.move(to: CGPoint(x: midX, y: 0))
                    path.addLine(to: CGPoint(x: midX, y: geo.size.height))
                case .teeJunction:
                    path.move(to: CGPoint(x: midX, y: 0))
                    path.addLine(to: CGPoint(x: midX, y: geo.size.height))
                    path.move(to: CGPoint(x: midX, y: tickY))
                    path.addLine(to: CGPoint(x: geo.size.width, y: tickY))
                case .corner:
                    path.move(to: CGPoint(x: midX, y: 0))
                    path.addLine(to: CGPoint(x: midX, y: tickY))
                    path.addLine(to: CGPoint(x: geo.size.width, y: tickY))
                }
            }
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .frame(width: GuideMetrics.indent)
    }
}

/// A single project leaf. The checkbox binds to the live `SelectionTree` (`projectBinding`)
/// — never a value read from the derived tree — so it can never show stale state. It shows
/// `leaf.name` (the last path segment) with the full `path` as a `.help` tooltip; orphans
/// (empty path) fall back to `encodedName`.
private struct LeafRow: View {
    let leaf: ProjectPathTree.Leaf
    let isRunning: Bool
    let projectsMasterOn: Bool
    let isOn: Binding<Bool>
    /// Manage-only pre-run signal for this project's folder ("… — Claude data only");
    /// `nil` (and rendered as nothing) on Backup and Restore.
    var caption: String? = nil

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(leaf.name.isEmpty ? leaf.encodedName : leaf.name)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(leaf.isSelectable ? .primary : .secondary)
                    .help(leaf.path)
                if let summary = leaf.incompleteSummary {
                    Text(summary).font(.caption2)
                        .foregroundStyle(leaf.isSelectable ? .orange : .secondary)
                }
                if let caption {
                    Text(caption).font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isRunning || !projectsMasterOn || !leaf.isSelectable)
    }
}
