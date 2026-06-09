import XCTest
@testable import ArchiveCore

final class ArchiveEngineSelectorExtensionPolicyTests: XCTestCase {
    func testInProcessOnlyPolicyUsesLibArchiveForSevenZipListing() throws {
        let selector = ArchiveEngineSelector(selectionPolicy: .inProcessOnly)

        let engine = try selector.engineType(for: .sevenZip, requestedCapabilities: [.listContents])

        XCTAssertEqual(engine, .libarchive)
    }

    func testInProcessOnlyPolicyRejectsFormatsThatOnlyHaveSubprocessEngines() {
        let selector = ArchiveEngineSelector(selectionPolicy: .inProcessOnly)

        XCTAssertThrowsError(try selector.engineType(for: .xz, requestedCapabilities: [.listContents])) { error in
            XCTAssertEqual(error as? ArchiveEngineSelectionError, .unsupportedCapabilities([.listContents], .xz))
        }
    }

    func testInProcessOnlyPolicyNeverSelectsExternalRarCreate() {
        let selector = ArchiveEngineSelector(externalRarConfigured: true, selectionPolicy: .inProcessOnly)

        XCTAssertThrowsError(try selector.engineType(for: .rar, requestedCapabilities: [.externalCreate])) { error in
            XCTAssertEqual(error as? ArchiveEngineSelectionError, .unsupportedCapabilities([.externalCreate], .rar))
        }
    }
}
