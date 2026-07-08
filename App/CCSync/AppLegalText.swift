import Foundation

/// Single source of the app's legal wording. The disclaimer text lives here (and
/// nowhere else); the MIT license text and the copyright line are read from the
/// bundled root `LICENSE` resource so they are never duplicated in code.
enum AppLegalText {
    /// First-launch disclaimer, based on the README "Disclaimer" section. Kept short
    /// and factual — no legal wording is invented beyond what the README states.
    static let disclaimer = """
    Use CCSync at your own risk.

    During restore, CCSync overwrites files under your home directory — \
    ~/.claude, ~/.claude.json, and per-project .claude/settings.local.json files.

    Before overwriting anything, restore writes a snapshot of the current state to \
    ~/.claude/.ccsync-backups/<timestamp>/. Even so, keep your own backups of \
    anything you cannot afford to lose.

    The software is provided "as is", without warranty of any kind. The author \
    accepts no liability for data loss or any other damages arising from its use. \
    See the MIT license (available in About) for the full terms.
    """

    /// The full MIT license text, read from the bundled root `LICENSE` resource.
    ///
    /// The file has no extension, so it is looked up with `withExtension: nil`. If the
    /// resource is missing, the fallback still points the reader to the canonical
    /// LICENSE in the repository so the terms remain locatable.
    static var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return """
            License text unavailable in this build. See the LICENSE file in the \
            project repository:
            https://github.com/HawkeyePierce89/CCSync/blob/master/LICENSE
            """
        }
        return text
    }

    /// The copyright line, derived verbatim from the bundled LICENSE text (the single
    /// source of truth). Scans the license lines for the one starting with
    /// "Copyright"; returns an empty string if no such line is present.
    static var copyright: String {
        for line in licenseText.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Copyright") {
                return trimmed
            }
        }
        return ""
    }
}
