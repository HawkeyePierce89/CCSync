import XCTest
@testable import CCSyncCore

/// Covers the `removeItem` primitive on the in-memory `FileSystem`: file
/// removal, recursive directory removal (journalled as a single `.removeItem`
/// for the root), the missing-path throw, the injectable fault hook, and that
/// unrelated paths survive.
final class FileSystemRemoveItemTests: XCTestCase {

    private struct FaultError: Error, Equatable {}

    func testRemoveFile() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("/root/a.txt", "hello")
        fs.seedFile("/root/b.txt", "keep")

        try fs.removeItem("/root/a.txt")

        XCTAssertFalse(fs.exists("/root/a.txt"))
        XCTAssertTrue(fs.exists("/root/b.txt"))
        XCTAssertTrue(fs.journal.contains(.removeItem("/root/a.txt")))
    }

    func testRemoveDirectoryRecursively() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("/root/dir/a.txt", "a")
        fs.seedFile("/root/dir/sub/b.txt", "b")
        fs.seedDirectory("/root/dir/empty")
        fs.seedFile("/root/other.txt", "keep")

        try fs.removeItem("/root/dir")

        XCTAssertFalse(fs.exists("/root/dir"))
        XCTAssertFalse(fs.exists("/root/dir/a.txt"))
        XCTAssertFalse(fs.exists("/root/dir/sub/b.txt"))
        XCTAssertFalse(fs.exists("/root/dir/empty"))
        XCTAssertTrue(fs.exists("/root/other.txt"))

        // A single `.removeItem` for the root — not one per descendant.
        let removals = fs.journal.filter {
            if case .removeItem = $0 { return true }
            return false
        }
        XCTAssertEqual(removals, [.removeItem("/root/dir")])
    }

    func testRemoveTrailingSlashDirectory() throws {
        let fs = InMemoryFileSystem()
        fs.seedFile("/root/dir/a.txt", "a")

        try fs.removeItem("/root/dir/")

        XCTAssertFalse(fs.exists("/root/dir"))
        XCTAssertFalse(fs.exists("/root/dir/a.txt"))
    }

    func testRemoveMissingPathThrows() {
        let fs = InMemoryFileSystem()
        fs.seedFile("/root/a.txt", "a")

        XCTAssertThrowsError(try fs.removeItem("/root/missing")) { error in
            XCTAssertEqual(error as? FileSystemError, .notFound("/root/missing"))
        }
    }

    func testFaultHookThrows() {
        let fs = InMemoryFileSystem()
        fs.seedFile("/root/a.txt", "a")
        fs.removeItemErrors["/root/a.txt"] = FaultError()

        XCTAssertThrowsError(try fs.removeItem("/root/a.txt")) { error in
            XCTAssertTrue(error is FaultError)
        }
        // The forced fault must not have deleted the file.
        XCTAssertTrue(fs.exists("/root/a.txt"))
    }

    func testUnrelatedPrefixSiblingIsUntouched() throws {
        let fs = InMemoryFileSystem()
        // "/root/dir2" shares the "/root/dir" prefix but is a distinct sibling.
        fs.seedFile("/root/dir/a.txt", "a")
        fs.seedFile("/root/dir2/b.txt", "b")

        try fs.removeItem("/root/dir")

        XCTAssertFalse(fs.exists("/root/dir/a.txt"))
        XCTAssertTrue(fs.exists("/root/dir2/b.txt"))
    }

    func testRemoveSymlinkEntryOnly() throws {
        let fs = InMemoryFileSystem()
        fs.seedSymlink("/root/link")

        try fs.removeItem("/root/link")

        XCTAssertFalse(fs.exists("/root/link"))
        XCTAssertFalse(fs.isSymlink("/root/link"))
    }
}
