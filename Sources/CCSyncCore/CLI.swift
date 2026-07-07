import Foundation

/// Headless entry point for the `ccsync` executable. All behaviour lives here in
/// Core so it runs on an `InMemoryFileSystem` in tests and produces the exact same
/// result the GUI does (acceptance #7). `Sources/ccsync/main.swift` is only a thin
/// wire-up: it builds a real `Environment` and forwards `CommandLine.arguments`.
///
/// Commands:
///   - `backup [--out <path>]`
///   - `list --archive <path>`               → machine-readable JSON project list
///   - `restore --archive <path>` with an explicit selection:
///       `--global` / `--no-global`, `--projects` / `--no-projects`,
///       repeatable `--project <path>` (restrict to the named source paths).
public enum CCSyncCLI {

    /// Everything the runner needs from the outside world, injected so tests can
    /// drive it deterministically without touching the real disk.
    public struct Environment {
        public var fileSystem: FileSystem
        /// Home directory of the machine this runs on (source on backup, target on
        /// restore). Determines the username used for remapping.
        public var home: String
        /// Sink for machine-readable output (JSON project lists / reports).
        public var stdout: (String) -> Void
        /// Sink for diagnostics and errors.
        public var stderr: (String) -> Void
        /// Target Claude Code version provider for the advisory restore check.
        public var versionProvider: ClaudeVersionProvider?
        /// Override the source username recorded at backup (defaults to the home leaf).
        public var sourceUser: String?
        /// Source Claude Code version stamped into the manifest at backup time.
        public var sourceClaudeVersion: String?

        public init(
            fileSystem: FileSystem,
            home: String,
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            versionProvider: ClaudeVersionProvider? = nil,
            sourceUser: String? = nil,
            sourceClaudeVersion: String? = nil
        ) {
            self.fileSystem = fileSystem
            self.home = home
            self.stdout = stdout
            self.stderr = stderr
            self.versionProvider = versionProvider
            self.sourceUser = sourceUser
            self.sourceClaudeVersion = sourceClaudeVersion
        }
    }

    /// Run one command. `arguments` excludes the program name. Returns a process
    /// exit code: `0` on success, non-zero on a usage error or a stop condition.
    public static func run(_ arguments: [String], environment env: Environment) -> Int32 {
        guard let command = arguments.first else {
            env.stderr(usage)
            return 2
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "backup":
                return try runBackup(rest, env: env)
            case "list":
                return try runList(rest, env: env)
            case "restore":
                return try runRestore(rest, env: env)
            case "-h", "--help", "help":
                env.stdout(usage)
                return 0
            default:
                env.stderr("ccsync: unknown command '\(command)'\n\(usage)")
                return 2
            }
        } catch let error as CLIError {
            env.stderr("ccsync: \(error.message)")
            return error.code
        } catch {
            env.stderr("ccsync: \(error)")
            return 1
        }
    }

    // MARK: - backup

    private static func runBackup(_ args: [String], env: Environment) throws -> Int32 {
        var parser = ArgParser(args)
        let out = try parser.optionValue("--out")
        try parser.finish()

        let paths = KnownPaths(home: env.home)
        let service = BackupService(
            fileSystem: env.fileSystem,
            paths: paths,
            sourceUser: env.sourceUser,
            sourceClaudeVersion: env.sourceClaudeVersion
        )
        let destination = try service.backup(to: out)
        env.stdout(destination)
        return 0
    }

    // MARK: - list

    private static func runList(_ args: [String], env: Environment) throws -> Int32 {
        var parser = ArgParser(args)
        let archivePath = try parser.requiredOptionValue("--archive")
        try parser.finish()

        let data = try readArchive(archivePath, env: env)
        let plan = try RestorePlan(archive: data)
        let json = try plan.serialized(pretty: true)
        env.stdout(String(decoding: json, as: UTF8.self))
        return 0
    }

    // MARK: - restore

    private static func runRestore(_ args: [String], env: Environment) throws -> Int32 {
        var parser = ArgParser(args)
        let archivePath = try parser.requiredOptionValue("--archive")
        let globalFlag = parser.boolFlag(on: "--global", off: "--no-global")
        let projectsFlag = parser.boolFlag(on: "--projects", off: "--no-projects")
        let projectPaths = parser.repeatedOptionValues("--project")
        try parser.finish()

        let data = try readArchive(archivePath, env: env)
        let plan = try RestorePlan(archive: data)
        var tree = SelectionTree(plan: plan)

        // A `--project` restricts the run to exactly the named source paths.
        if !projectPaths.isEmpty {
            for index in tree.projects.indices { tree.projects[index].isSelected = false }
            for path in projectPaths {
                guard let node = plan.projects.first(where: { $0.path == path }) else {
                    env.stderr("ccsync: warning: no project with path '\(path)' in the archive")
                    continue
                }
                tree.setProject(encodedName: node.encodedName, true)
            }
        }
        if let globalFlag { tree.setGlobal(globalFlag) }
        if let projectsFlag { tree.setProjectsMaster(projectsFlag) }

        let paths = KnownPaths(home: env.home)
        let service = RestoreService(
            fileSystem: env.fileSystem,
            paths: paths,
            versionProvider: env.versionProvider
        )
        let report = try service.restore(archive: data, selection: tree.resolvedSelection())
        env.stdout(String(decoding: try reportJSON(report), as: UTF8.self))
        for warning in report.warnings { env.stderr("ccsync: warning: \(warning)") }
        return 0
    }

    // MARK: - Helpers

    private static func readArchive(_ path: String, env: Environment) throws -> Data {
        guard env.fileSystem.exists(path) else {
            throw CLIError("archive not found: \(path)", code: 1)
        }
        return try env.fileSystem.readData(path)
    }

    /// Serialise a `RestoreReport` to machine-readable JSON for the CLI contract.
    private static func reportJSON(_ report: RestoreReport) throws -> Data {
        var object: [String: JSONValue] = [
            "globalRestored": .bool(report.globalRestored),
            "restoredProjects": .array(report.restoredProjects.map(JSONValue.string)),
            "skippedProjects": .array(report.skippedProjects.map { skipped in
                .object([
                    "path": .string(skipped.path),
                    "encodedName": .string(skipped.encodedName),
                    "reason": .string(skipped.reason),
                ])
            }),
            "warnings": .array(report.warnings.map(JSONValue.string)),
        ]
        if let snapshotPath = report.snapshotPath {
            object["snapshotPath"] = .string(snapshotPath)
        }
        return try JSONValue.object(object).serialized(pretty: true)
    }

    static let usage = """
        ccsync — backup & restore Claude Code config and history

        Usage:
          ccsync backup [--out <path>]
          ccsync list --archive <path>
          ccsync restore --archive <path> [--global|--no-global]
                         [--projects|--no-projects] [--project <path> ...]
        """
}

// MARK: - Errors

/// A usage or stop-condition error carrying an exit code.
struct CLIError: Error {
    let message: String
    let code: Int32
    init(_ message: String, code: Int32 = 2) {
        self.message = message
        self.code = code
    }
}

// MARK: - Minimal argument parser

/// A tiny hand-rolled option parser (no external dependency). It supports
/// `--opt value`, boolean on/off pairs, and repeatable `--opt value` options,
/// and rejects any leftover/unknown tokens.
private struct ArgParser {
    private var tokens: [String]

    init(_ tokens: [String]) { self.tokens = tokens }

    /// Consume `name value`, returning the value, or `nil` if `name` is absent.
    mutating func optionValue(_ name: String) throws -> String? {
        guard let index = tokens.firstIndex(of: name) else { return nil }
        guard index + 1 < tokens.count else {
            throw CLIError("option \(name) requires a value")
        }
        let value = tokens[index + 1]
        tokens.removeSubrange(index...(index + 1))
        return value
    }

    /// Like `optionValue`, but the option is mandatory.
    mutating func requiredOptionValue(_ name: String) throws -> String {
        guard let value = try optionValue(name) else {
            throw CLIError("missing required option \(name)")
        }
        return value
    }

    /// Consume all occurrences of `name value`, in order.
    mutating func repeatedOptionValues(_ name: String) -> [String] {
        var values: [String] = []
        while let index = tokens.firstIndex(of: name) {
            guard index + 1 < tokens.count else {
                tokens.remove(at: index)
                break
            }
            values.append(tokens[index + 1])
            tokens.removeSubrange(index...(index + 1))
        }
        return values
    }

    /// A tri-state boolean: `true` if `on` present, `false` if `off` present,
    /// `nil` if neither (caller keeps its default).
    mutating func boolFlag(on: String, off: String) -> Bool? {
        var result: Bool?
        if let index = tokens.firstIndex(of: on) { tokens.remove(at: index); result = true }
        if let index = tokens.firstIndex(of: off) { tokens.remove(at: index); result = false }
        return result
    }

    /// Fail if any tokens are left unconsumed.
    func finish() throws {
        if let leftover = tokens.first {
            throw CLIError("unexpected argument '\(leftover)'")
        }
    }
}
