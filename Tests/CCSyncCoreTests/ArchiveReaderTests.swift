import XCTest
@testable import CCSyncCore

final class ArchiveReaderTests: XCTestCase {

    // A model with global config, one complete project (main session + linked
    // artifacts) and one incomplete project (entry with no on-disk directory).
    private func sampleModel() -> BackupModel {
        let global = GlobalConfig(
            settings: Data(#"{"theme":"dark"}"#.utf8),
            claudeMD: Data("# rules".utf8),
            configDirs: [
                ConfigDir(name: "commands", files: [
                    FileBlob(relativePath: "deploy.md", data: Data("run".utf8))
                ])
            ],
            mcpServers: .object(["git": .object(["command": .string("git-mcp")])])
        )
        let session = SessionArtifacts(
            sessionID: "aaaa",
            isSubAgent: false,
            transcript: FileBlob(relativePath: "aaaa.jsonl", data: Data("transcript".utf8)),
            fileHistory: [FileBlob(relativePath: "edit-1.json", data: Data("fh".utf8))]
        )
        let complete = ProjectEntry(
            path: "/Users/alice/git/App",
            encodedName: "-Users-alice-git-App",
            settings: .object(["allowedTools": .array([.string("Bash")])]),
            localSettings: Data(#"{"local":true}"#.utf8),
            sessions: [session]
        )
        let incomplete = ProjectEntry(
            path: "/Users/alice/git/Ghost",
            encodedName: "-Users-alice-git-Ghost",
            incomplete: true,
            incompleteReason: "directory missing"
        )
        return BackupModel(sourceUser: "alice", global: global, projects: [complete, incomplete])
    }

    private func sampleArchive(version: String? = "1.2.3") throws -> Data {
        try ArchiveWriter().makeArchive(from: sampleModel(), sourceClaudeVersion: version)
    }

    // MARK: - Valid parse

    func testReadsManifestFromValidArchive() throws {
        let reader = try ArchiveReader(data: try sampleArchive())
        XCTAssertEqual(reader.manifest.formatVersion, Manifest.currentFormatVersion)
        XCTAssertEqual(reader.manifest.sourceUser, "alice")
        XCTAssertEqual(reader.manifest.sourceClaudeVersion, "1.2.3")
        XCTAssertEqual(reader.manifest.projects.count, 2)
    }

    func testProjectListContract() throws {
        let plan = try RestorePlan(archive: try sampleArchive())
        XCTAssertEqual(plan.sourceUser, "alice")
        XCTAssertEqual(plan.sourceClaudeVersion, "1.2.3")
        XCTAssertEqual(plan.projects.map(\.path), ["/Users/alice/git/App", "/Users/alice/git/Ghost"])

        let ghost = try XCTUnwrap(plan.projects.first { $0.path.hasSuffix("Ghost") })
        XCTAssertTrue(ghost.incomplete)
        XCTAssertEqual(ghost.incompleteReason, "directory missing")

        let app = try XCTUnwrap(plan.projects.first { $0.path.hasSuffix("App") })
        XCTAssertFalse(app.incomplete)
        XCTAssertEqual(app.encodedName, "-Users-alice-git-App")
        XCTAssertEqual(app.settings, .object(["allowedTools": .array([.string("Bash")])]))
    }

    func testProjectListSerialisesToJSON() throws {
        let plan = try RestorePlan(archive: try sampleArchive())
        let json = try JSONValue(data: try plan.serialized())
        XCTAssertEqual(json["sourceUser"], .string("alice"))
        XCTAssertEqual(json["sourceClaudeVersion"], .string("1.2.3"))
        XCTAssertEqual(json["projects"]?.arrayValue?.count, 2)
    }

    func testPayloadAccess() throws {
        let reader = try ArchiveReader(data: try sampleArchive())
        XCTAssertEqual(reader.payload(at: ArchiveLayout.globalSettings), Data(#"{"theme":"dark"}"#.utf8))
        XCTAssertNil(reader.payload(at: "does/not/exist"))

        let appPaths = reader.payloadPaths(withPrefix: "projects/-Users-alice-git-App/")
        XCTAssertTrue(appPaths.contains("projects/-Users-alice-git-App/settings.local.json"))
        XCTAssertTrue(appPaths.contains(
            "projects/-Users-alice-git-App/sessions/aaaa/transcript/aaaa.jsonl"
        ))
        // The incomplete project contributes no payload entries.
        XCTAssertTrue(reader.payloadPaths(withPrefix: "projects/-Users-alice-git-Ghost/").isEmpty)
    }

    // MARK: - Corrupt / invalid archives (stop conditions)

    func testNonArchiveBytesThrow() {
        XCTAssertThrowsError(try ArchiveReader(data: Data("not an archive".utf8))) { error in
            XCTAssertEqual(error as? ArchiveError, .notAnArchive)
        }
    }

    func testTruncatedArchiveThrows() throws {
        let full = try sampleArchive()
        let truncated = Data(full.prefix(full.count / 2))
        XCTAssertThrowsError(try ArchiveReader(data: truncated)) { error in
            guard case .corrupt = (error as? ArchiveError) else {
                return XCTFail("expected .corrupt, got \(error)")
            }
        }
    }

    func testMissingManifestThrows() {
        let container = ArchiveContainer.pack([
            .init(path: ArchiveLayout.globalSettings, data: Data("x".utf8))
        ])
        XCTAssertThrowsError(try ArchiveReader(data: container)) { error in
            guard case .invalidManifest = (error as? ArchiveError) else {
                return XCTFail("expected .invalidManifest, got \(error)")
            }
        }
    }

    func testInvalidManifestJSONThrows() {
        let container = ArchiveContainer.pack([
            .init(path: ArchiveLayout.manifest, data: Data("{ not json".utf8))
        ])
        XCTAssertThrowsError(try ArchiveReader(data: container)) { error in
            guard case .invalidManifest = (error as? ArchiveError) else {
                return XCTFail("expected .invalidManifest, got \(error)")
            }
        }
    }

    func testManifestMissingRequiredFieldThrows() {
        // Structurally valid JSON, but not a manifest (no sourceUser/projects).
        let container = ArchiveContainer.pack([
            .init(path: ArchiveLayout.manifest, data: Data(#"{"formatVersion":1}"#.utf8))
        ])
        XCTAssertThrowsError(try ArchiveReader(data: container)) { error in
            guard case .invalidManifest = (error as? ArchiveError) else {
                return XCTFail("expected .invalidManifest, got \(error)")
            }
        }
    }

    // MARK: - VersionCheck

    private struct StubProvider: ClaudeVersionProvider {
        let version: String?
        func currentVersion() -> String? { version }
    }

    func testVersionCheckMatchIsSilent() {
        let check = VersionCheck(sourceVersion: "1.2.3", targetVersion: "1.2.3")
        XCTAssertEqual(check.outcome, .match)
        XCTAssertNil(check.warning)
        XCTAssertFalse(check.isBlocking)
    }

    func testVersionCheckMismatchWarns() {
        let check = VersionCheck(sourceVersion: "1.2.3", targetVersion: "2.0.0")
        XCTAssertEqual(check.outcome, .mismatch(source: "1.2.3", target: "2.0.0"))
        XCTAssertNotNil(check.warning)
        XCTAssertFalse(check.isBlocking)
    }

    func testVersionCheckTargetUnknownIsSoftWarning() {
        let check = VersionCheck(sourceVersion: "1.2.3", targetVersion: nil)
        XCTAssertEqual(check.outcome, .targetUnknown)
        XCTAssertNotNil(check.warning)
        XCTAssertFalse(check.isBlocking)
    }

    func testVersionCheckSourceUnknownIsSoftWarning() {
        let check = VersionCheck(sourceVersion: nil, targetVersion: "1.2.3")
        XCTAssertEqual(check.outcome, .sourceUnknown)
        XCTAssertNotNil(check.warning)
        XCTAssertFalse(check.isBlocking)
    }

    func testVersionCheckFromManifestAndProvider() throws {
        let reader = try ArchiveReader(data: try sampleArchive(version: "1.0.0"))
        XCTAssertEqual(
            VersionCheck(manifest: reader.manifest, provider: StubProvider(version: "1.0.0")).outcome,
            .match
        )
        XCTAssertEqual(
            VersionCheck(manifest: reader.manifest, provider: StubProvider(version: "9.9.9")).outcome,
            .mismatch(source: "1.0.0", target: "9.9.9")
        )
        XCTAssertEqual(
            VersionCheck(manifest: reader.manifest, provider: StubProvider(version: nil)).outcome,
            .targetUnknown
        )
    }

    func testCommandVersionParsing() {
        XCTAssertEqual(CommandClaudeVersionProvider.parseVersion(from: "1.2.3 (Claude Code)"), "1.2.3")
        XCTAssertEqual(CommandClaudeVersionProvider.parseVersion(from: "claude 2.0.0\n"), "2.0.0")
        XCTAssertEqual(CommandClaudeVersionProvider.parseVersion(from: "v1.4.0-beta.1"), "1.4.0-beta.1")
        XCTAssertNil(CommandClaudeVersionProvider.parseVersion(from: "no version here"))
    }
}
