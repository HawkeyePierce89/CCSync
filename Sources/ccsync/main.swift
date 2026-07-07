import CCSyncCore
import Foundation

// Thin wire-up: build a real environment and forward the command line to Core.
// All logic lives in `CCSyncCLI` so the same code path is exercised by tests on
// an in-memory filesystem (acceptance #7 — the core runs without the GUI).

private func writeLine(_ text: String, to handle: FileHandle) {
    handle.write(Data((text + "\n").utf8))
}

let environment = CCSyncCLI.Environment(
    fileSystem: RealFileSystem(),
    home: NSHomeDirectory(),
    stdout: { writeLine($0, to: .standardOutput) },
    stderr: { writeLine($0, to: .standardError) },
    versionProvider: CommandClaudeVersionProvider(),
    sourceClaudeVersion: CommandClaudeVersionProvider().currentVersion()
)

let exitCode = CCSyncCLI.run(Array(CommandLine.arguments.dropFirst()), environment: environment)
exit(exitCode)
