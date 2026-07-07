import SwiftUI
import CCSyncCore

/// Backup screen: choose a destination directory (default — the home directory),
/// run, and show the result. The actual work runs off the main thread so the UI
/// never blocks (`isRunning` drives a progress indicator).
///
/// The view is a thin renderer: it only reads state off the view model and calls
/// `run()`. All packing logic lives in `CCSyncCore.BackupService`.
struct BackupView: View {
    @StateObject private var model = BackupViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Backup")
                .font(.title2).bold()

            Text("Packs the global Claude Code config, a manifest of projects with "
               + "their settings, and their history into a single archive. "
               + "Credentials and local noise are excluded.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            HStack(spacing: 12) {
                Button {
                    model.run()
                } label: {
                    Text("Run Backup")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning)

                if model.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

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
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Owns the destination selection and drives `BackupService` off the main actor.
@MainActor
final class BackupViewModel: ObservableObject {
    /// A successful backup path, or a failure message.
    enum Result {
        case success(String)
        case failure(String)
    }

    /// `nil` destination means the default — the home directory.
    @Published private(set) var destination: String?
    @Published private(set) var isRunning = false
    @Published private(set) var result: Result?

    var destinationDisplay: String {
        destination ?? "Home folder (default)"
    }

    /// Present a directory picker; a cancel leaves the current choice untouched.
    func chooseDestination() {
        if let path = AppPanels.chooseDirectory() {
            destination = path
            result = nil
        }
    }

    /// Run the backup off the main thread, then publish the result on the main actor.
    func run() {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        let destination = self.destination
        Task {
            let outcome = await Self.performBackup(to: destination)
            self.isRunning = false
            self.result = outcome
        }
    }

    /// Bridge to the synchronous Core API on a background executor.
    private static func performBackup(to destination: String?) async -> Result {
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
                let path = try service.backup(to: destination)
                return .success(path)
            } catch {
                return .failure("Backup failed: \(error)")
            }
        }.value
    }
}
