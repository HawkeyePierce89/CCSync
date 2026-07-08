import XCTest
@testable import CCSyncCore

final class UserRemapTests: XCTestCase {

    // MARK: - Absolute paths

    func testRemapAbsolutePathPrefix() {
        let remap = UserRemap(from: "alice", to: "bob")
        XCTAssertEqual(
            remap.remapAbsolutePath("/Users/alice/git/CCSync"),
            "/Users/bob/git/CCSync"
        )
    }

    func testRemapAbsolutePathExactHome() {
        let remap = UserRemap(from: "alice", to: "bob")
        XCTAssertEqual(remap.remapAbsolutePath("/Users/alice"), "/Users/bob")
    }

    func testRemapAbsolutePathOnlyReplacesUserSegment() {
        // A nested "alice" that is not the user segment must survive.
        let remap = UserRemap(from: "alice", to: "bob")
        XCTAssertEqual(
            remap.remapAbsolutePath("/Users/alice/projects/alice/notes"),
            "/Users/bob/projects/alice/notes"
        )
    }

    // MARK: - Encoded project directory names

    func testRemapEncodedProjectName() {
        let remap = UserRemap(from: "alice", to: "bob")
        XCTAssertEqual(
            remap.remapEncodedProjectName("-Users-alice-git-CCSync"),
            "-Users-bob-git-CCSync"
        )
    }

    func testRemapEncodedProjectNameOnlyReplacesUserSegment() {
        let remap = UserRemap(from: "alice", to: "bob")
        XCTAssertEqual(
            remap.remapEncodedProjectName("-Users-alice-projects-alice-notes"),
            "-Users-bob-projects-alice-notes"
        )
    }

    /// Usernames with non-alphanumeric characters are encoded (`.`/`_` → `-`)
    /// inside the `projects/` directory name, so the encoded form must be matched
    /// and substituted — not the raw username (acceptance #3).
    func testRemapEncodedProjectNameHandlesSpecialCharUsernames() {
        let remap = UserRemap(from: "alice.smith", to: "bob_jones")
        // The on-disk directory encodes `alice.smith` as `alice-smith`.
        XCTAssertEqual(
            remap.remapEncodedProjectName("-Users-alice-smith-git-CCSync"),
            "-Users-bob-jones-git-CCSync"
        )
        // Absolute paths keep the real (raw) usernames.
        XCTAssertEqual(
            remap.remapAbsolutePath("/Users/alice.smith/git/CCSync"),
            "/Users/bob_jones/git/CCSync"
        )
    }

    // MARK: - Idempotence / no-op when usernames match

    func testNoOpWhenUsernamesMatch() {
        let remap = UserRemap(from: "alice", to: "alice")
        XCTAssertTrue(remap.isNoOp)
        XCTAssertEqual(
            remap.remapAbsolutePath("/Users/alice/git"),
            "/Users/alice/git"
        )
        XCTAssertEqual(
            remap.remapEncodedProjectName("-Users-alice-git"),
            "-Users-alice-git"
        )
    }

    func testRemapIsIdempotentAcrossReapplication() {
        let remap = UserRemap(from: "alice", to: "bob")
        let once = remap.remapAbsolutePath("/Users/alice/git")
        // Applying again should not change an already-remapped path.
        XCTAssertEqual(remap.remapAbsolutePath(once), "/Users/bob/git")
    }

    // MARK: - No false positives

    func testNoFalsePositiveWhenUsersNotPrefix() {
        let remap = UserRemap(from: "alice", to: "bob")
        // "Users" appears mid-path, not as the leading segment.
        XCTAssertEqual(
            remap.remapAbsolutePath("/opt/Users/alice/data"),
            "/opt/Users/alice/data"
        )
    }

    func testNoFalsePositiveOnDifferentUser() {
        let remap = UserRemap(from: "alice", to: "bob")
        // The user segment is "carol", not "alice" — leave untouched.
        XCTAssertEqual(
            remap.remapAbsolutePath("/Users/carol/git"),
            "/Users/carol/git"
        )
        XCTAssertEqual(
            remap.remapEncodedProjectName("-Users-carol-git"),
            "-Users-carol-git"
        )
    }

    func testNoFalsePositiveOnSimilarPrefix() {
        // "aliceb" starts with "alice" but is a different user.
        let remap = UserRemap(from: "alice", to: "bob")
        XCTAssertEqual(
            remap.remapAbsolutePath("/Users/aliceb/git"),
            "/Users/aliceb/git"
        )
        XCTAssertEqual(
            remap.remapEncodedProjectName("-Users-aliceb-git"),
            "-Users-aliceb-git"
        )
    }
}
