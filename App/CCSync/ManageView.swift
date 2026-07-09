import SwiftUI
import CCSyncCore

/// Manage screen: permanently delete a project's Claude Code footprint, or that
/// footprint plus the project folder on disk. Nothing is selected by default and
/// the destructive action is gated behind an irreversibility modal — there is no
/// snapshot and no undo (the snapshot policy is restore-only).
///
/// Like Backup and Restore this is a dumb renderer: it binds to the
/// `SelectionTree` Core builds from a `ManagePlan`, forwards every toggle to a Core
/// mutation helper, and calls `DeleteService`. All selection and delete semantics
/// live in `CCSyncCore`; the pre-run folder captions come straight from
/// `ManagePlan.folderCaption`.
struct ManageView: View {
    @StateObject private var model = ManageViewModel()

    /// Drives the `.confirmationDialog`. Set true by "Delete…", cleared on cancel or
    /// after the run kicks off — deletion only happens on the destructive confirm.
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Text("Permanently removes selected projects' Claude Code history and "
               + "settings, and optionally their folder on disk. This cannot be "
               + "undone — no snapshot is taken.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.tree != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        selection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if model.errorMessage == nil {
                Text("Reading local config…")
                    .foregroundStyle(.secondary)
            }

            operationRow
            runRow

            if let report = model.report {
                DeleteReportView(report: report)
            } else if let error = model.errorMessage {
                GroupBox {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.loadPlanIfNeeded() }
    }

    private var header: some View {
        HStack {
            Text("Manage").font(.title2).bold()
            Spacer()
            Button("Refresh") { model.reloadPlan() }
                .disabled(model.isRunning)
        }
    }

    @ViewBuilder
    private var selection: some View {
        ProjectSelectionTreeView(
            tree: model.projectTree,
            isRunning: model.isRunning,
            // No master toggle is shown; leaves are always live on the Manage tree.
            projectsMasterOn: true,
            folderState: model.folderState,
            toggleFolder: model.toggleFolder,
            projectBinding: model.projectBinding,
            leafCaption: model.folderCaption
        )
    }

    private var operationRow: some View {
        Picker("", selection: $model.operation) {
            Text("Delete Claude data").tag(DeleteOperation.claudeDataOnly)
            Text("Delete project entirely").tag(DeleteOperation.entireProject)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(model.isRunning || model.tree == nil)
    }

    private var runRow: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                confirming = true
            } label: {
                Text("Delete…")
            }
            .disabled(model.isRunning || !model.hasSelection)

            if model.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { model.run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.confirmationMessage)
        }
    }

    private var confirmationTitle: String {
        let count = model.selectionCount
        return "Permanently delete \(count) project\(count == 1 ? "" : "s")?"
    }
}

/// Renders a `DeleteReport`: what was deleted (with a folder-removed indicator),
/// what was skipped and why, and any warnings — styled like `RestoreView`'s report.
private struct DeleteReportView: View {
    let report: DeleteReport

    var body: some View {
        GroupBox(report.dryRun ? "Result (dry run — nothing changed)" : "Result") {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.deletedProjects, id: \.encodedName) { deleted in
                        Label(
                            label(for: deleted),
                            systemImage: deleted.folderRemoved ? "trash.fill" : "trash"
                        )
                        .lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(report.skippedProjects, id: \.encodedName) { skipped in
                        Label("\(rowTitle(skipped.path, skipped.encodedName)) — \(skipped.reason)",
                              systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    ForEach(report.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
    }

    private func label(for deleted: DeleteReport.DeletedProject) -> String {
        let title = rowTitle(deleted.path, deleted.encodedName)
        return deleted.folderRemoved ? "\(title) — folder removed" : title
    }

    private func rowTitle(_ path: String, _ encodedName: String) -> String {
        path.isEmpty ? encodedName : path
    }
}

/// Owns the `SelectionTree` (built from a `ManagePlan` read off the local machine),
/// the chosen `DeleteOperation`, forwards every toggle to a Core mutation helper,
/// and drives `DeleteService` off the main actor. No selection or delete logic is
/// implemented here — folder captions and modal counts come from `ManagePlan`.
@MainActor
final class ManageViewModel: ObservableObject {
    @Published private(set) var tree: SelectionTree?
    @Published private(set) var isRunning = false
    @Published private(set) var report: DeleteReport?
    @Published private(set) var errorMessage: String?
    @Published var operation: DeleteOperation = .claudeDataOnly

    /// Retained for `folderCaption` and `deletionSplit` — the Core pre-run signal.
    private var managePlan: ManagePlan?

    /// Guards `loadPlanIfNeeded()` so switching tabs does not rebuild the tree (and
    /// discard the user's selection). `reloadPlan()` resets it.
    private var didLoadPlan = false

    /// The grouped, collapsible view of the current projects, derived fresh from the
    /// live tree. Carries no selection state — the renderer reads/writes selection via
    /// `projectBinding`/`folderState`/`toggleFolder`.
    var projectTree: ProjectPathTree { ProjectPathTree(nodes: tree?.projects ?? []) }

    /// Number of projects currently selected for deletion.
    var selectionCount: Int { tree?.resolvedSelection().projectEncodedNames.count ?? 0 }

    /// The Delete button is live only with a loaded plan and at least one project on.
    var hasSelection: Bool { tree != nil && selectionCount > 0 }

    /// The confirmation modal copy: states the permanence and, for "entirely", the
    /// `ManagePlan.deletionSplit` N/M counts.
    var confirmationMessage: String {
        var lines = [operation == .entireProject
            ? "This permanently deletes the selected projects' Claude data and their "
              + "folder on disk. It cannot be undone — no snapshot is taken."
            : "This permanently deletes the selected projects' Claude data (history "
              + "and settings). It cannot be undone — no snapshot is taken."]
        if operation == .entireProject, let managePlan, let tree {
            let split = managePlan.deletionSplit(selection: tree.resolvedSelection())
            lines.append("\(split.folders) project folder"
                + "\(split.folders == 1 ? "" : "s") will be deleted, "
                + "\(split.dataOnly) will have Claude data cleaned only.")
        }
        return lines.joined(separator: "\n\n")
    }

    /// The Core folder caption for a project row (`nil` for a deletable/orphan row).
    func folderCaption(_ encodedName: String) -> String? {
        managePlan?.folderCaption(for: encodedName)
    }

    /// Tri-state of a folder from the selection of its descendant leaves. `.off` when
    /// the plan has not loaded yet.
    func folderState(_ descendantEncodedNames: [String]) -> FolderCheckState {
        tree?.folderState(descendantEncodedNames: descendantEncodedNames) ?? .off
    }

    /// Cascade a folder toggle to its descendant leaves via Core; a no-op before the
    /// plan loads.
    func toggleFolder(_ descendantEncodedNames: [String], _ on: Bool) {
        tree?.setFolder(descendantEncodedNames: descendantEncodedNames, on)
    }

    func projectBinding(_ encodedName: String) -> Binding<Bool> {
        Binding(
            get: { self.tree?.projects.first { $0.encodedName == encodedName }?.isSelected ?? false },
            set: { self.tree?.setProject(encodedName: encodedName, $0) }
        )
    }

    // MARK: - Plan loading

    /// Build the plan once on first appearance. A no-op if it already loaded, so
    /// switching tabs never resets the user's selection.
    func loadPlanIfNeeded() {
        guard !didLoadPlan else { return }
        didLoadPlan = true
        loadPlan(clearReport: true)
    }

    /// Rebuild the plan on demand (the header "Refresh" button), discarding the
    /// current tree, selection, and any prior report.
    func reloadPlan() {
        didLoadPlan = true
        loadPlan(clearReport: true)
    }

    /// Load (or reload) the tree off the main thread. `clearReport` is false after a
    /// completed delete so its report stays visible while the list drops the
    /// now-deleted projects.
    private func loadPlan(clearReport: Bool) {
        tree = nil
        errorMessage = nil
        if clearReport { report = nil }
        Task {
            let outcome = await Self.buildPlan()
            switch outcome {
            case .success(let plan):
                self.managePlan = plan
                self.tree = SelectionTree(managePlan: plan)
                self.errorMessage = nil
            case .failure(let message):
                self.managePlan = nil
                self.tree = nil
                self.errorMessage = message
            }
        }
    }

    private enum PlanOutcome {
        case success(ManagePlan)
        case failure(String)
    }

    /// Read the local inventory + folder statuses off the main thread.
    private static func buildPlan() async -> PlanOutcome {
        await Task.detached(priority: .userInitiated) { () -> PlanOutcome in
            let home = NSHomeDirectory()
            do {
                let plan = try ManagePlan(
                    fileSystem: RealFileSystem(),
                    paths: KnownPaths(home: home)
                )
                return .success(plan)
            } catch {
                return .failure("Could not read local config: \(error)")
            }
        }.value
    }

    // MARK: - Actions

    /// Resolve the tree to an explicit `Selection` and run the (real) delete off the
    /// main thread, then publish the report and reload the list so deleted projects
    /// disappear. Called only from the confirmation modal's destructive button.
    func run() {
        guard !isRunning, let tree else { return }
        isRunning = true
        report = nil
        errorMessage = nil
        let selection = tree.resolvedSelection()
        let operation = self.operation
        Task {
            let outcome = await Self.performDelete(selection: selection, operation: operation)
            self.isRunning = false
            switch outcome {
            case .success(let report):
                self.report = report
                // Rebuild the list so the just-deleted projects drop out, keeping the
                // report on screen.
                self.loadPlan(clearReport: false)
            case .failure(let message):
                self.errorMessage = message
            }
        }
    }

    private enum Outcome {
        case success(DeleteReport)
        case failure(String)
    }

    private static func performDelete(selection: Selection, operation: DeleteOperation) async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            let home = NSHomeDirectory()
            let service = DeleteService(
                fileSystem: RealFileSystem(),
                paths: KnownPaths(home: home)
            )
            do {
                let report = try service.delete(selection: selection, operation: operation, dryRun: false)
                return .success(report)
            } catch {
                return .failure("Delete failed: \(error)")
            }
        }.value
    }
}
