import SwiftUI
import CCSyncCore

/// Restore screen. Open an archive, then the view renders the `SelectionTree`
/// produced by Core:
///   - a standalone "Global config" toggle,
///   - a "Projects" master — when off, the per-project toggles are inert,
///   - a toggle per project from the archive, all checked by default.
/// Running calls `RestoreService` and shows the resulting `RestoreReport`,
/// including any skipped projects. The view builds nothing itself: every toggle
/// forwards to a `SelectionTree` mutation helper in Core.
struct RestoreView: View {
    @StateObject private var model = RestoreViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if model.tree == nil {
                Text("Open a CCSync archive to choose what to restore.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        selection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                runRow
            }

            if let report = model.report {
                ReportView(report: report)
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
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore").font(.title2).bold()
                Text(model.archiveDisplay)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Open Archive…") { model.chooseArchive() }
                .disabled(model.isRunning)
        }
    }

    @ViewBuilder
    private var selection: some View {
        if let source = model.sourceSummary {
            Text(source).font(.footnote).foregroundStyle(.secondary)
        }

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
            Button("Run Restore") { model.run() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning)
            if model.isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Renders a `RestoreReport`: what was restored, what was skipped and why, warnings.
private struct ReportView: View {
    let report: RestoreReport

    var body: some View {
        GroupBox("Result") {
            // Bound a long report (e.g. ~50 restored projects) so it scrolls
            // internally instead of pushing the Run button off-screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if report.globalRestored {
                        Label("Global config restored", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(report.restoredProjects, id: \.self) { path in
                        Label(path, systemImage: "checkmark.circle")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(report.skippedProjects, id: \.encodedName) { skipped in
                        Label("\(skipped.path) — \(skipped.reason)", systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    ForEach(report.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let snapshot = report.snapshotPath {
                        Text("Snapshot: \(snapshot)")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
    }
}

/// Holds the opened archive bytes and the `SelectionTree`, and forwards every
/// toggle to a Core mutation helper. No selection logic is implemented here.
@MainActor
final class RestoreViewModel: ObservableObject {
    @Published private(set) var archivePath: String?
    @Published private(set) var tree: SelectionTree?
    @Published private(set) var isRunning = false
    @Published private(set) var report: RestoreReport?
    @Published private(set) var errorMessage: String?

    private var archiveData: Data?
    private var plan: RestorePlan?

    var archiveDisplay: String { archivePath ?? "No archive opened" }

    var sourceSummary: String? {
        guard let plan else { return nil }
        var parts = ["Source user: \(plan.sourceUser)"]
        if let version = plan.sourceClaudeVersion {
            parts.append("Claude Code \(version)")
        }
        return parts.joined(separator: " · ")
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

    // MARK: - Actions

    /// Open an archive and load its project list (the Task 4 contract) into a
    /// default `SelectionTree` (global on, master on, every project checked).
    func chooseArchive() {
        guard let path = AppPanels.chooseArchive() else { return }
        report = nil
        errorMessage = nil
        do {
            let data = try RealFileSystem().readData(path)
            let plan = try RestorePlan(archive: data)
            archivePath = path
            archiveData = data
            self.plan = plan
            tree = SelectionTree(plan: plan)
        } catch {
            archivePath = path
            archiveData = nil
            plan = nil
            tree = nil
            errorMessage = "Could not read archive: \(error)"
        }
    }

    /// Resolve the tree to a flat `Selection` and run the restore off the main
    /// thread; publish the report on the main actor.
    func run() {
        guard !isRunning, let data = archiveData, let tree else { return }
        isRunning = true
        report = nil
        errorMessage = nil
        let selection = tree.resolvedSelection()
        Task {
            let outcome = await Self.performRestore(data: data, selection: selection)
            self.isRunning = false
            switch outcome {
            case .success(let report): self.report = report
            case .failure(let message): self.errorMessage = message
            }
        }
    }

    private enum Outcome {
        case success(RestoreReport)
        case failure(String)
    }

    private static func performRestore(data: Data, selection: Selection) async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            let home = NSHomeDirectory()
            let service = RestoreService(
                fileSystem: RealFileSystem(),
                paths: KnownPaths(home: home),
                versionProvider: CommandClaudeVersionProvider()
            )
            do {
                let report = try service.restore(archive: data, selection: selection)
                return .success(report)
            } catch {
                return .failure("Restore failed: \(error)")
            }
        }.value
    }
}
