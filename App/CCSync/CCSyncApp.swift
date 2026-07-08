import SwiftUI

/// SwiftUI entry point. The app is a thin layer over `CCSyncCore`: every screen
/// renders a value produced by Core (a destination path, a `SelectionTree`, a
/// `RestoreReport`) and calls the same backup/list/restore contract the `ccsync`
/// CLI uses. No business logic and no selection-tree building live here.
@main
struct CCSyncApp: App {
    /// First-launch acknowledgement of the disclaimer. UI state only (UserDefaults) —
    /// not selection, so the "logic lives in Core" invariant is untouched.
    @AppStorage("didAcknowledgeDisclaimer") private var didAcknowledgeDisclaimer = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 560, minHeight: 460)
                .sheet(isPresented: .constant(!didAcknowledgeDisclaimer)) {
                    DisclaimerSheet { didAcknowledgeDisclaimer = true }
                }
        }
        .windowResizability(.contentMinSize)
    }
}

/// Two screens — Backup and Restore — behind a tab picker. Both are dumb renderers
/// over their view models, which forward to Core.
struct RootView: View {
    private enum Tab: Hashable { case backup, restore }
    @State private var tab: Tab = .backup

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Backup").tag(Tab.backup)
                Text("Restore").tag(Tab.restore)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            switch tab {
            case .backup:
                BackupView()
            case .restore:
                RestoreView()
            }
        }
    }
}
