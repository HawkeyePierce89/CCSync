import Foundation

/// Headless entry point for the `ccsync` executable. All behaviour lives here in
/// Core so it runs on an `InMemoryFileSystem` in tests and produces the exact same
/// result the GUI does (acceptance #7). `Sources/ccsync/main.swift` is only a thin
/// wire-up: it builds a real `Environment` and forwards `CommandLine.arguments`.
///
/// Commands:
///   - `backup [--out <path>]` with an optional explicit selection:
///       `--global` / `--no-global`, `--projects` / `--no-projects`,
///       repeatable `--project <path>` (restrict to the named local paths).
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
        let parser = try ArgParser(
            args,
            valueOptions: ["--out"],
            repeatedOptions: ["--project"],
            boolFlags: [.init(on: "--global", off: "--no-global"),
                        .init(on: "--projects", off: "--no-projects")]
        )
        let out = parser.optionValue("--out")
        let projectPaths = parser.repeatedOptionValues("--project")
        let globalFlag = parser.boolFlag(on: "--global")
        let projectsFlag = parser.boolFlag(on: "--projects")

        let paths = KnownPaths(home: env.home)
        let plan = try BackupPlan(fileSystem: env.fileSystem, paths: paths, sourceUser: env.sourceUser)
        var tree = SelectionTree(plan: plan)

        // A `--project` restricts the run to exactly the named source paths — same
        // order of application as `runRestore`: reset all, enable by path match.
        if !projectPaths.isEmpty {
            for index in tree.projects.indices { tree.projects[index].isSelected = false }
            for path in projectPaths {
                guard let node = plan.projects.first(where: { $0.path == path }) else {
                    env.stderr("ccsync: warning: no project with path '\(path)' on this machine")
                    continue
                }
                tree.setProject(encodedName: node.encodedName, true)
            }
        }
        if let globalFlag { tree.setGlobal(globalFlag) }
        if let projectsFlag { tree.setProjectsMaster(projectsFlag) }

        let service = BackupService(
            fileSystem: env.fileSystem,
            paths: paths,
            sourceUser: env.sourceUser,
            sourceClaudeVersion: env.sourceClaudeVersion
        )
        // Always pass an explicit, non-nil Selection (never the backward-compat
        // `nil` default) — even the no-flags case resolves the all-on tree.
        let destination = try service.backup(to: out, selection: tree.resolvedSelection())
        env.stdout(destination)
        return 0
    }

    // MARK: - list

    private static func runList(_ args: [String], env: Environment) throws -> Int32 {
        let parser = try ArgParser(args, valueOptions: ["--archive"])
        let archivePath = try parser.requiredOptionValue("--archive")

        let data = try readArchive(archivePath, env: env)
        let plan = try RestorePlan(archive: data)
        let json = try plan.serialized(pretty: true)
        env.stdout(String(decoding: json, as: UTF8.self))
        return 0
    }

    // MARK: - restore

    private static func runRestore(_ args: [String], env: Environment) throws -> Int32 {
        let parser = try ArgParser(
            args,
            valueOptions: ["--archive"],
            repeatedOptions: ["--project"],
            boolFlags: [.init(on: "--global", off: "--no-global"),
                        .init(on: "--projects", off: "--no-projects")]
        )
        let archivePath = try parser.requiredOptionValue("--archive")
        let projectPaths = parser.repeatedOptionValues("--project")
        let globalFlag = parser.boolFlag(on: "--global")
        let projectsFlag = parser.boolFlag(on: "--projects")

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
          ccsync backup [--out <path>] [--global|--no-global]
                        [--projects|--no-projects] [--project <path> ...]
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
/// and rejects any unknown token.
///
/// Parsing is a single left-to-right pass over the *original* token stream, so
/// option/value adjacency is validated against the tokens the user actually
/// typed — nothing is removed out of order. A `--`-prefixed token sitting where
/// a value option expects its value is therefore always a usage error
/// (`--out --no-global`, `--project --out <path> <projectPath>`, a dangling
/// trailing `--project`), never a silent misbind that swallows a flag as a value
/// and leaves the user's opt-out or output path misapplied. A singleton value
/// option given twice (`--archive a --archive b`) is likewise a usage error, not
/// a silent last-wins — only `repeatedOptions` may recur.
private struct ArgParser {
    /// A boolean flag as an on/off token pair.
    struct BoolFlag {
        let on: String
        let off: String
    }

    private var values: [String: String] = [:]
    private var repeated: [String: [String]] = [:]
    /// Groups (keyed by `on`) where the `on` / `off` token was seen. `off` wins
    /// on conflict, matching the documented `--global --no-global` semantics.
    private var boolOn: Set<String> = []
    private var boolOff: Set<String> = []

    init(
        _ tokens: [String],
        valueOptions: Set<String> = [],
        repeatedOptions: Set<String> = [],
        boolFlags: [BoolFlag] = []
    ) throws {
        var boolLookup: [String: (key: String, value: Bool)] = [:]
        for flag in boolFlags {
            boolLookup[flag.on] = (flag.on, true)
            boolLookup[flag.off] = (flag.on, false)
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if valueOptions.contains(token) || repeatedOptions.contains(token) {
                guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
                    throw CLIError("option \(token) requires a value")
                }
                let value = tokens[index + 1]
                if repeatedOptions.contains(token) {
                    repeated[token, default: []].append(value)
                } else {
                    guard values[token] == nil else {
                        throw CLIError("option \(token) specified more than once")
                    }
                    values[token] = value
                }
                index += 2
            } else if let bool = boolLookup[token] {
                if bool.value { boolOn.insert(bool.key) } else { boolOff.insert(bool.key) }
                index += 1
            } else {
                throw CLIError("unexpected argument '\(token)'")
            }
        }
    }

    /// The value of a value option, or `nil` if it was absent.
    func optionValue(_ name: String) -> String? { values[name] }

    /// Like `optionValue`, but the option is mandatory.
    func requiredOptionValue(_ name: String) throws -> String {
        guard let value = values[name] else {
            throw CLIError("missing required option \(name)")
        }
        return value
    }

    /// All values of a repeatable option, in the order given.
    func repeatedOptionValues(_ name: String) -> [String] { repeated[name] ?? [] }

    /// A tri-state boolean: `true` if `on` present, `false` if `off` present
    /// (`off` wins if both appear), `nil` if neither (caller keeps its default).
    func boolFlag(on: String) -> Bool? {
        if boolOff.contains(on) { return false }
        if boolOn.contains(on) { return true }
        return nil
    }
}
