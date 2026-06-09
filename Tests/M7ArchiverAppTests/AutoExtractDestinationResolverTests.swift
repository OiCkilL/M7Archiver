import XCTest
@testable import M7ArchiverApp

final class AutoExtractDestinationResolverTests: XCTestCase {
    private let testHome = URL(fileURLWithPath: "/Users/test")

    func testFinderTargetTakesPrecedenceOverStrategy() {
        let result = AutoExtractDestinationResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/tmp/archive.zip"),
            finderTarget: URL(fileURLWithPath: "/Users/finder/here"),
            strategy: .downloads,
            bookmark: nil,
            homeDirectoryURL: testHome
        )
        XCTAssertEqual(result?.folderURL.path, "/Users/finder/here")
        XCTAssertEqual(result?.requiresSecurityScope, false)
    }

    func testSameFolderUsesArchiveParent() {
        let result = AutoExtractDestinationResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/Users/x/Downloads/a.zip"),
            finderTarget: nil,
            strategy: .sameFolder,
            bookmark: nil,
            homeDirectoryURL: testHome
        )
        XCTAssertEqual(result?.folderURL.path, "/Users/x/Downloads")
        XCTAssertEqual(result?.requiresSecurityScope, false)
    }

    func testDownloadsResolvesUnderProvidedHomeDirectory() {
        let result = AutoExtractDestinationResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/tmp/x.zip"),
            finderTarget: nil,
            strategy: .downloads,
            bookmark: nil,
            homeDirectoryURL: testHome
        )
        XCTAssertEqual(result?.folderURL.path, "/Users/test/Downloads")
        XCTAssertEqual(result?.requiresSecurityScope, false)
    }

    func testCustomBookmarkWithoutDataReturnsNil() {
        let result = AutoExtractDestinationResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/tmp/x.zip"),
            finderTarget: nil,
            strategy: .customBookmark,
            bookmark: nil,
            homeDirectoryURL: testHome
        )
        XCTAssertNil(result)
    }

    func testCustomBookmarkWithGarbageDataReturnsNil() {
        let result = AutoExtractDestinationResolver.resolve(
            archiveURL: URL(fileURLWithPath: "/tmp/x.zip"),
            finderTarget: nil,
            strategy: .customBookmark,
            bookmark: Data([0x00, 0x01, 0x02]),
            homeDirectoryURL: testHome
        )
        XCTAssertNil(result)
    }

    func testArchiveStemStripsKnownPairedExtensions() {
        XCTAssertEqual(
            AutoExtractDestinationResolver.archiveStem(for: URL(fileURLWithPath: "/x/proj.tar.gz")),
            "proj"
        )
        XCTAssertEqual(
            AutoExtractDestinationResolver.archiveStem(for: URL(fileURLWithPath: "/x/snap.TAR.ZST")),
            "snap"
        )
        XCTAssertEqual(
            AutoExtractDestinationResolver.archiveStem(for: URL(fileURLWithPath: "/x/log.tar.bz2")),
            "log"
        )
    }

    func testArchiveStemStripsSingleExtension() {
        XCTAssertEqual(
            AutoExtractDestinationResolver.archiveStem(for: URL(fileURLWithPath: "/x/data.7z")),
            "data"
        )
        XCTAssertEqual(
            AutoExtractDestinationResolver.archiveStem(for: URL(fileURLWithPath: "/x/foo.zip")),
            "foo"
        )
    }

    func testArchiveStemKeepsExtensionlessNames() {
        XCTAssertEqual(
            AutoExtractDestinationResolver.archiveStem(for: URL(fileURLWithPath: "/x/random")),
            "random"
        )
    }
}
