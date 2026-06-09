import XCTest
import ArchiveCore
@testable import M7ArchiverApp

final class ArchiveSessionExtractionTests: XCTestCase {
    @MainActor
    func testExtractWithNoArchiveReturnsMissingArchive() async {
        let session = ArchiveSession()
        let outcome = await session.extract(to: URL(fileURLWithPath: "/tmp/m7-test"))
        XCTAssertEqual(outcome, .missingArchive)
    }

    @MainActor
    func testExtractSelectedWithNoArchiveReturnsMissingArchive() async {
        let session = ArchiveSession()
        let outcome = await session.extractSelected(to: URL(fileURLWithPath: "/tmp/m7-test"))
        XCTAssertEqual(outcome, .missingArchive)
    }
}
