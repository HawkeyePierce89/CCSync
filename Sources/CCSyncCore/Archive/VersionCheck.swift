import Foundation

/// Supplies the target machine's Claude Code version at restore time.
///
/// There is no formal session schema version, so the Claude Code app version is
/// used as a proxy (see "Decisions before start", item 4). The source version is
/// written into the manifest at backup time; the target version is obtained here.
public protocol ClaudeVersionProvider {
    /// The Claude Code version on this machine, or `nil` if it cannot be
    /// determined (missing binary, unreadable output). A `nil` result must not
    /// stop a restore — it degrades to a soft warning.
    func currentVersion() -> String?
}

/// Compares the source Claude Code version (from the manifest) against the
/// target version obtained via a `ClaudeVersionProvider`.
///
/// This is a heuristic warning only — it never blocks a restore. A mismatch, an
/// unrecorded source version, or an undeterminable target version each produce a
/// soft warning and processing continues.
public struct VersionCheck: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Source and target versions are identical.
        case match
        /// Both versions are known but differ.
        case mismatch(source: String, target: String)
        /// The manifest did not record a source version.
        case sourceUnknown
        /// The target machine's version could not be determined.
        case targetUnknown
    }

    public let outcome: Outcome

    /// Compare two already-resolved version strings.
    public init(sourceVersion: String?, targetVersion: String?) {
        guard let source = sourceVersion else {
            outcome = .sourceUnknown
            return
        }
        guard let target = targetVersion else {
            outcome = .targetUnknown
            return
        }
        outcome = (source == target) ? .match : .mismatch(source: source, target: target)
    }

    /// Compare the manifest's source version against the provider's target.
    public init(manifest: Manifest, provider: ClaudeVersionProvider) {
        self.init(
            sourceVersion: manifest.sourceClaudeVersion,
            targetVersion: provider.currentVersion()
        )
    }

    /// The version check is advisory: it never blocks a restore.
    public var isBlocking: Bool { false }

    /// A human-readable warning, or `nil` when the versions match.
    public var warning: String? {
        switch outcome {
        case .match:
            return nil
        case let .mismatch(source, target):
            return "Claude Code version differs: backup was made with \(source), "
                + "this machine has \(target). Restore continues; session resume "
                + "may behave inconsistently."
        case .sourceUnknown:
            return "The backup does not record a Claude Code version; "
                + "skipping the version compatibility check."
        case .targetUnknown:
            return "Could not determine this machine's Claude Code version; "
                + "skipping the version compatibility check."
        }
    }
}

/// Target-version source (locked for Task 4): invoke `claude --version` and parse
/// the version token from its output. Any failure (missing binary, non-zero exit,
/// unparseable output) yields `nil`, which `VersionCheck` treats as a soft warning.
public struct CommandClaudeVersionProvider: ClaudeVersionProvider {
    private let launchPath: String
    private let arguments: [String]

    /// - Parameters:
    ///   - launchPath: executable to run (defaults to `/usr/bin/env` so `claude`
    ///     is resolved via `PATH`).
    ///   - arguments: arguments passed to it (defaults to `claude --version`).
    public init(launchPath: String = "/usr/bin/env", arguments: [String] = ["claude", "--version"]) {
        self.launchPath = launchPath
        self.arguments = arguments
    }

    public func currentVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Self.parseVersion(from: output)
    }

    /// Extract the first version-looking token (e.g. `1.2.3`) from command output
    /// such as `"1.2.3 (Claude Code)"`. Returns `nil` if none is found.
    static func parseVersion(from output: String) -> String? {
        let separators = CharacterSet(charactersIn: " \t\n\r()")
        for raw in output.components(separatedBy: separators) {
            var token = raw
            if token.hasPrefix("v") { token.removeFirst() }
            guard let first = token.first, first.isNumber, token.contains(".") else {
                continue
            }
            if token.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter }) {
                return token
            }
        }
        return nil
    }
}
