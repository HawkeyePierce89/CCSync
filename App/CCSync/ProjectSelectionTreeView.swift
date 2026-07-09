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
    /// Optional extra caption per leaf, keyed by encoded name — the Manage screen's
    /// Core folder caption ("folder already gone — Claude data only" etc.). Defaults
    /// to none so Backup and Restore reuse the view unchanged.
    var leafCaption: (String) -> String? = { _ in nil }

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
                    leafCaption: leafCaption,
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
                            isOn: projectBinding(leaf.encodedName),
                            caption: leafCaption(leaf.encodedName)
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
    let leafCaption: (String) -> String?
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
                        leafCaption: leafCaption,
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
                isOn: projectBinding(leaf.encodedName),
                caption: leafCaption(leaf.encodedName)
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
        // A real Button (not an Image + onTapGesture) so the tri-state control is
        // keyboard-focusable, carries the button trait, and honours `.disabled` for
        // VoiceOver. Its accessibility value announces on/off/mixed. `.plain` keeps the
        // borderless checkbox+label look; the DisclosureGroup's own chevron still drives
        // expand/collapse separately.
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

/// A single project leaf, identical in appearance to the pre-tree flat row. The checkbox
/// binds to the live `SelectionTree` (`projectBinding`) — never a value read from the
/// derived tree — so it can never show stale state.
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
                Text(leaf.path.isEmpty ? leaf.encodedName : leaf.path)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(leaf.isSelectable ? .primary : .secondary)
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
