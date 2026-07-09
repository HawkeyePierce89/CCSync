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

    /// Opens the dedicated About window (below) so its scrollable content is guaranteed.
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 560, minHeight: 460)
                .sheet(isPresented: .constant(!didAcknowledgeDisclaimer)) {
                    DisclaimerSheet { didAcknowledgeDisclaimer = true }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Replace the stock About item so it opens our own panel with the full,
            // scrollable license text instead of the default (truncated) alert.
            CommandGroup(replacing: .appInfo) {
                Button("About CCSync") { openWindow(id: Self.aboutWindowID) }
            }
        }

        Window("About CCSync", id: Self.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }

    /// Stable identifier for the About `Window` scene, referenced by `openWindow`.
    private static let aboutWindowID = "about"
}

/// Three screens — Backup, Restore, and Manage — behind a tab picker. All are dumb
/// renderers over their view models, which forward to Core. Each view owns its
/// `@StateObject`, so switching tabs never resets another screen's selection.
struct RootView: View {
    private enum Tab: Hashable { case backup, restore, manage }
    @State private var tab: Tab = .backup

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Backup").tag(Tab.backup)
                Text("Restore").tag(Tab.restore)
                Text("Manage").tag(Tab.manage)
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
            case .manage:
                ManageView()
            }
        }
    }
}
