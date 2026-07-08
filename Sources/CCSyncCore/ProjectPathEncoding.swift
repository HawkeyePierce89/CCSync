import Foundation

/// Encodes an absolute project path into its `projects/` directory name.
///
/// Claude Code names history directories by replacing every non-alphanumeric
/// character with `-`, e.g. `/Users/alice/git/CCSync` → `-Users-alice-git-CCSync`.
///
/// This is used only to *link* a `~/.claude.json` project key to its on-disk
/// history directory at collection time. Remapping between machines never
/// re-encodes — it substitutes the user segment on the original name (see
/// `UserRemap`). If a project's real directory name diverges from this rule the
/// link simply fails to match and the project is recorded as incomplete.
public enum ProjectPathEncoding {
    public static func encode(_ path: String) -> String {
        String(path.map { character in
            (character.isASCII && (character.isLetter || character.isNumber)) ? character : "-"
        })
    }
}
