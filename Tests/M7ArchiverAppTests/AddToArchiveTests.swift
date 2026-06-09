import XCTest
@testable import M7ArchiverApp

final class AddToArchiveTests: XCTestCase {
    func testSuggestedStemForSingleFileUsesFilenameWithoutExtension() {
        let url = URL(fileURLWithPath: "/Users/evan/Downloads/foo.txt")
        XCTAssertEqual(AddToArchive.suggestedStem(for: [url]), "foo")
    }

    func testSuggestedStemForSingleFolderUsesFolderName() {
        let url = URL(fileURLWithPath: "/Users/evan/Projects/site", isDirectory: true)
        XCTAssertEqual(AddToArchive.suggestedStem(for: [url]), "site")
    }

    func testSuggestedStemForSingleFolderWithDotPreservesFullFolderName() throws {
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("AddToArchiveTests.\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("Folder.v1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(AddToArchive.suggestedStem(for: [folder]), "Folder.v1")
    }

    func testSuggestedStemForMultipleSiblingsUsesParentFolderName() {
        let urls = [
            URL(fileURLWithPath: "/Users/evan/Photos/a.jpg"),
            URL(fileURLWithPath: "/Users/evan/Photos/b.jpg"),
            URL(fileURLWithPath: "/Users/evan/Photos/c.jpg")
        ]
        XCTAssertEqual(AddToArchive.suggestedStem(for: urls), "Photos")
    }

    func testSuggestedStemForCrossDirectorySelectionFallsBackToArchive() {
        let urls = [
            URL(fileURLWithPath: "/Users/evan/Photos/a.jpg"),
            URL(fileURLWithPath: "/Users/evan/Documents/b.pdf")
        ]
        XCTAssertEqual(AddToArchive.suggestedStem(for: urls), "Archive")
    }

    func testSuggestedStemForEmptyListFallsBackToArchive() {
        XCTAssertEqual(AddToArchive.suggestedStem(for: []), "Archive")
    }

    func testPreferredDestinationDirectoryPrefersFinderTargetWhenAvailable() throws {
        let targetBase = FileManager.default.temporaryDirectory.appendingPathComponent("AddToArchiveTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetBase) }

        let sources = [URL(fileURLWithPath: "/Users/evan/Photos/a.jpg")]
        let preferred = AddToArchive.preferredDestinationDirectory(for: sources, finderTarget: targetBase)
        XCTAssertEqual(preferred?.standardizedFileURL.path, targetBase.standardizedFileURL.path)
    }

    func testPreferredDestinationDirectoryFallsBackToFirstSourceParent() {
        let sources = [URL(fileURLWithPath: "/Users/evan/Photos/a.jpg")]
        let preferred = AddToArchive.preferredDestinationDirectory(for: sources, finderTarget: nil)
        XCTAssertEqual(preferred?.path, "/Users/evan/Photos")
    }

    func testPreferredDestinationDirectoryWithFileTargetUsesParent() {
        let target = URL(fileURLWithPath: "/Users/evan/Documents/notes.txt")
        let sources = [URL(fileURLWithPath: "/Users/evan/Photos/a.jpg")]
        let preferred = AddToArchive.preferredDestinationDirectory(for: sources, finderTarget: target)
        XCTAssertEqual(preferred?.path, "/Users/evan/Documents")
    }
}
