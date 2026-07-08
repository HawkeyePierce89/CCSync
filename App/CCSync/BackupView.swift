import SwiftUI
import CCSyncCore

/// Backup screen: choose a destination directory (default — the home directory),
/// pick what to include via the `SelectionTree` Core builds from a `BackupPlan`,
/// run, and show the result. The plan is read off the local machine on first
/// appearance; the actual work runs off the main thread so the UI never blocks
/// (`isRunning` drives a progress indicator).
///
/// The view is a thin renderer: it reads state off the view model, forwards every
/// toggle to a `SelectionTree` mutation helper in Core, and calls `run()`. All
/// packing and selection logic lives in `CCSyncCore`.
struct BackupView: View {
    @StateObject private var model = BackupViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Text("Packs the global Claude Code config, a manifest of projects with "
               + "their settings, and their history into a single archive. "
               + "Credentials and local noise are excluded.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            destinationRow

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

            runRow

            if let result = model.result {
                GroupBox {
                    switch result {
                    case .success(let path):
                        Label("Backup written to \(path)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
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
            Text("Backup").font(.title2).bold()
            Spacer()
            Button("Refresh") { model.reloadPlan() }
                .disabled(model.isRunning)
        }
    }

    private var destinationRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Destination folder").font(.subheadline).bold()
                Text(model.destinationDisplay)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") { model.chooseDestination() }
                .disabled(model.isRunning)
        }
    }

    @ViewBuilder
    private var selection: some View {
        Toggle("Global config", isOn: model.globalBinding)
            .disabled(model.isRunning)

        Toggle("Projects", isOn: model.projectsMasterBinding)
            .bold()
            .disabled(model.isRunning)

        ForEach(model.projectRows, id: \.encodedName) { row in
            Toggle(isOn: model.projectBinding(row.encodedName)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.path.isEmpty ? row.encodedName : row.path)
                        .lineLimit(1).truncationMode(.middle)
                    if let summary = row.incompleteSummary {
                        Text(summary).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.leading, 20)
            .disabled(model.isRunning || !model.projectsMasterOn)
        }
    }

    private var runRow: some View {
        HStack(spacing: 12) {
            Button {
                model.run()
            } label: {
                Text("Run Backup")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isRunning || model.tree == nil)

            if model.isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Owns the destination selection and the `SelectionTree` (built from a
/// `BackupPlan` read off the local machine), forwards every toggle to a Core
/// mutation helper, and drives `BackupService` off the main actor. No selection
/// logic is implemented here.
@MainActor
final class BackupViewModel: ObservableObject {
    /// A successful backup path, or a failure message.
    enum Result {
        case success(String)
        case failure(String)
    }

    /// `nil` destination means the default — the home directory.
    @Published private(set) var destination: String?
    @Published private(set) var tree: SelectionTree?
    @Published private(set) var isRunning = false
    @Published private(set) var result: Result?
    @Published private(set) var errorMessage: String?

    /// Guards `loadPlanIfNeeded()` so switching Backup↔Restore does not rebuild
    /// the tree (and discard the user's selection). `reloadPlan()` resets it.
    private var didLoadPlan = false

    var destinationDisplay: String {
        destination ?? "Home folder (default)"
    }

    var projectRows: [SelectionTree.Node] { tree?.projects ?? [] }
    var projectsMasterOn: Bool { tree?.projectsMasterSelected ?? false }

    // MARK: - Bindings that forward to Core mutation helpers

    var globalBinding: Binding<Bool> {
        Binding(
            get: { self.tree?.globalSelected ?? false },
            set: { self.tree?.setGlobal($0) }
        )
    }

    var projectsMasterBinding: Binding<Bool> {
        Binding(
            get: { self.tree?.projectsMasterSelected ?? false },
            set: { self.tree?.setProjectsMaster($0) }
        )
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
        loadPlan()
    }

    /// Rebuild the plan on demand (the header "Refresh" button), discarding the
    /// current tree and selection.
    func reloadPlan() {
        didLoadPlan = true
        tree = nil
        errorMessage = nil
        // Clear any previous backup result too: the body renders `result` ahead of
        // `errorMessage`, so a stale success/failure would hide a new plan-load
        // error. Refresh starts a clean interaction.
        result = nil
        loadPlan()
    }

    private func loadPlan() {
        Task {
            let outcome = await Self.buildPlan()
            switch outcome {
            case .success(let plan):
                self.tree = SelectionTree(plan: plan)
                self.errorMessage = nil
            case .failure(let message):
                self.tree = nil
                self.errorMessage = message
            }
        }
    }

    private enum PlanOutcome {
        case success(BackupPlan)
        case failure(String)
    }

    /// Read the local inventory off the main thread.
    private static func buildPlan() async -> PlanOutcome {
        await Task.detached(priority: .userInitiated) { () -> PlanOutcome in
            let home = NSHomeDirectory()
            do {
                let plan = try BackupPlan(
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

    /// Present a directory picker; a cancel leaves the current choice untouched.
    func chooseDestination() {
        if let path = AppPanels.chooseDirectory() {
            destination = path
            result = nil
        }
    }

    /// Resolve the tree to an explicit `Selection` and run the backup off the main
    /// thread, then publish the result on the main actor. The guard makes it a
    /// no-op while running or before the plan loads, so a `nil` selection is never
    /// passed to Core.
    func run() {
        guard !isRunning, let tree else { return }
        isRunning = true
        result = nil
        let destination = self.destination
        let selection = tree.resolvedSelection()
        Task {
            let outcome = await Self.performBackup(to: destination, selection: selection)
            self.isRunning = false
            self.result = outcome
        }
    }

    /// Bridge to the synchronous Core API on a background executor.
    private static func performBackup(to destination: String?, selection: Selection) async -> Result {
        await Task.detached(priority: .userInitiated) { () -> Result in
            let home = NSHomeDirectory()
            let service = BackupService(
                fileSystem: RealFileSystem(),
                paths: KnownPaths(home: home),
                // Stamp the source Claude Code version so the restore-side
                // compatibility advisory works for GUI-created archives too
                // (parity with the CLI in Sources/ccsync/main.swift).
                sourceClaudeVersion: CommandClaudeVersionProvider().currentVersion()
            )
            do {
                let path = try service.backup(to: destination, selection: selection)
                return .success(path)
            } catch {
                return .failure("Backup failed: \(error)")
            }
        }.value
    }
}
