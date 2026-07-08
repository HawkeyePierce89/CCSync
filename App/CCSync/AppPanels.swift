import AppKit

/// Thin wrappers over `NSOpenPanel`. UI plumbing only — no app logic — kept in one
/// place so the view models stay focused on the Core contract.
enum AppPanels {
    /// Pick a single directory; returns its path, or `nil` on cancel.
    static func chooseDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    /// Pick a single archive file; returns its path, or `nil` on cancel.
    static func chooseArchive() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}
