import SwiftUI
import CCSyncCore

/// Shared recursive renderer for the grouped, collapsible project selection used by
/// both the Backup and Restore screens. It is a **dumb renderer** over a
/// `ProjectPathTree` (derived, selection-free): every checkbox reads and writes the
/// live `SelectionTree` through the injected closures, never a value snapshotted in
/// the tree. Inputs are plain values + closures so both view models reuse it without a
/// shared protocol.
///
/// Folders render as `DisclosureGroup`s, default-expanded: expansion state is kept in a
/// local `@State` map keyed by row id and read as `map[id] ?? true`, so row ids that
/// only appear later (e.g. after Refresh) still start expanded. A folder header is a
/// tri-state checkbox + label (tap: on→off, off/mixed→on) gated by `isRunning ||
/// !projectsMasterOn` — the same gating the leaves under it obey. Leaves keep today's
/// rendering (middle-truncated path, `incompleteSummary` caption, greyed + disabled when
/// non-selectable). Orphans render after the tree in a "History only — no project entry"
/// section using the same live leaf row, so they stay toggleable on Restore and greyed
/// on Backup exactly as before.
struct ProjectSelectionTreeView: View {
    let tree: ProjectPathTree
    let isRunning: Bool
    let projectsMasterOn: Bool
    let folderState: ([String]) -> FolderCheckState
    let toggleFolder: ([String], Bool) -> Void
    let projectBinding: (String) -> Binding<Bool>

    /// Expansion state keyed by row id. Absent id ⇒ expanded (`?? true`).
    @State private var expanded: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tree.roots) { row in
                TreeRow(
                    row: row,
                    isRunning: isRunning,
                    projectsMasterOn: projectsMasterOn,
                    folderState: folderState,
                    toggleFolder: toggleFolder,
                    projectBinding: projectBinding,
                    expanded: $expanded
                )
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
                            isOn: projectBinding(leaf.encodedName)
                        )
                    }
                }
            }
        }
    }
}

/// One row of the tree, recursing into folder children. Kept as a nested struct (not a
/// closure) so SwiftUI can drive the recursion through `DisclosureGroup`.
private struct TreeRow: View {
    let row: ProjectPathTree.Row
    let isRunning: Bool
    let projectsMasterOn: Bool
    let folderState: ([String]) -> FolderCheckState
    let toggleFolder: ([String], Bool) -> Void
    let projectBinding: (String) -> Binding<Bool>
    @Binding var expanded: [String: Bool]

    var body: some View {
        switch row {
        case .folder(let folder):
            DisclosureGroup(isExpanded: expansionBinding(folder.pathPrefix)) {
                ForEach(folder.children) { child in
                    TreeRow(
                        row: child,
                        isRunning: isRunning,
                        projectsMasterOn: projectsMasterOn,
                        folderState: folderState,
                        toggleFolder: toggleFolder,
                        projectBinding: projectBinding,
                        expanded: $expanded
                    )
                    .padding(.leading, 12)
                }
            } label: {
                folderHeader(folder)
            }
        case .project(let leaf):
            LeafRow(
                leaf: leaf,
                isRunning: isRunning,
                projectsMasterOn: projectsMasterOn,
                isOn: projectBinding(leaf.encodedName)
            )
        }
    }

    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded[id] ?? true },
            set: { expanded[id] = $0 }
        )
    }

    @ViewBuilder
    private func folderHeader(_ folder: ProjectPathTree.Folder) -> some View {
        let state = folderState(folder.descendantEncodedNames)
        let disabled = isRunning || !projectsMasterOn
        HStack(spacing: 6) {
            Image(systemName: checkboxImage(state))
                .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
            Text(folder.label)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(disabled ? .secondary : .primary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !disabled else { return }
            // Tap semantics: on → off, off/mixed → on.
            toggleFolder(folder.descendantEncodedNames, state != .on)
        }
    }

    private func checkboxImage(_ state: FolderCheckState) -> String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        }
    }
}

/// A single project leaf, identical in appearance to the pre-tree flat row. The checkbox
/// binds to the live `SelectionTree` (`projectBinding`) — never a value read from the
/// derived tree — so it can never show stale state.
private struct LeafRow: View {
    let leaf: ProjectPathTree.Leaf
    let isRunning: Bool
    let projectsMasterOn: Bool
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(leaf.path.isEmpty ? leaf.encodedName : leaf.path)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(leaf.isSelectable ? .primary : .secondary)
                if let summary = leaf.incompleteSummary {
                    Text(summary).font(.caption2)
                        .foregroundStyle(leaf.isSelectable ? .orange : .secondary)
                }
            }
        }
        .disabled(isRunning || !projectsMasterOn || !leaf.isSelectable)
    }
}
