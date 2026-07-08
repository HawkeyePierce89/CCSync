import CCSyncCore
import Foundation

// Thin wire-up: build a real environment and forward the command line to Core.
// All logic lives in `CCSyncCLI` so the same code path is exercised by tests on
// an in-memory filesystem (acceptance #7 — the core runs without the GUI).

private func writeLine(_ text: String, to handle: FileHandle) {
    handle.write(Data((text + "\n").utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

// Only `backup` stamps the source version into the manifest, so only shell out
// to `claude --version` for that command. Every other command (help, list,
// restore, unknown) would otherwise pay for — and could hang on — a needless
// subprocess. Restore reads the target version lazily via `versionProvider`.
let sourceClaudeVersion = arguments.first == "backup"
    ? CommandClaudeVersionProvider().currentVersion()
    : nil

let environment = CCSyncCLI.Environment(
    fileSystem: RealFileSystem(),
    home: NSHomeDirectory(),
    stdout: { writeLine($0, to: .standardOutput) },
    stderr: { writeLine($0, to: .standardError) },
    versionProvider: CommandClaudeVersionProvider(),
    sourceClaudeVersion: sourceClaudeVersion
)

let exitCode = CCSyncCLI.run(arguments, environment: environment)
exit(exitCode)
