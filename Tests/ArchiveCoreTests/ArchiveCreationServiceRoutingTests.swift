import XCTest
@testable import ArchiveCore

final class ArchiveCreationServiceRoutingTests: XCTestCase {
    private let selector = ArchiveEngineSelector(externalRarConfigured: false)

    private func capabilities(for profile: CompressionProfile) -> Set<ArchiveCapability> {
        ArchiveCreationService.requestedCapabilities(for: profile)
    }

    // MARK: - ZIP at every level resolves to libarchive (never advanced7z)

    func testZipAtEveryLevelResolvesToLibarchive() throws {
        for level in CompressionLevel.allCases {
            let profile = CompressionProfile(
                name: "ZIP",
                format: .zip,
                level: level
            )
            let engine = try selector.engineType(for: .zip, requestedCapabilities: capabilities(for: profile))
            XCTAssertEqual(engine, .libarchive, "ZIP level \(level)")
        }
    }

    // MARK: - 7z resolves to SevenZipEngine even without advanced7z

    func testSevenZipNormalResolvesToSevenZipEngine() throws {
        let profile = CompressionProfile(
            name: "7z normal",
            format: .sevenZip,
            level: .normal,
            method: "lzma2",
            solid: true
        )
        let engine = try selector.engineType(for: .sevenZip, requestedCapabilities: capabilities(for: profile))
        XCTAssertEqual(engine, .sevenZip)
    }

    // MARK: - advanced7z gate

    func testZipNormalDoesNotRequestAdvanced7z() {
        let profile = CompressionProfile(name: "ZIP", format: .zip, level: .normal)
        XCTAssertFalse(capabilities(for: profile).contains(.advanced7z))
    }

    func testZipAtUltraDoesNotRequestAdvanced7z() {
        // ZIP levels are user-selectable now. Defense in depth — even at
        // ZIP+ultra, the service must keep routing on libarchive and never
        // request advanced7z, since ZIP format definitions do not advertise
        // that capability.
        let profile = CompressionProfile(name: "ZIP", format: .zip, level: .ultra)
        XCTAssertFalse(capabilities(for: profile).contains(.advanced7z))
    }

    func testSevenZipUltraRequestsAdvanced7z() {
        let profile = CompressionProfile(name: "7z ultra", format: .sevenZip, level: .ultra)
        XCTAssertTrue(capabilities(for: profile).contains(.advanced7z))
    }

    func testSevenZipWithDictionarySizeRequestsAdvanced7z() {
        let profile = CompressionProfile(
            name: "7z dict",
            format: .sevenZip,
            level: .normal,
            dictionarySize: 64 * 1024 * 1024
        )
        XCTAssertTrue(capabilities(for: profile).contains(.advanced7z))
    }

    func testSevenZipNormalDoesNotRequestAdvanced7z() {
        let profile = CompressionProfile(
            name: "7z normal",
            format: .sevenZip,
            level: .normal,
            method: "lzma2",
            solid: true
        )
        // 7z normal+solid is no longer treated as "advanced" — the
        // SevenZipEngine handles it natively without needing the gate.
        XCTAssertFalse(capabilities(for: profile).contains(.advanced7z))
    }

    func testVolumeSizeRequestsCreateVolumes() {
        let profile = CompressionProfile(
            name: "7z split",
            format: .sevenZip,
            level: .normal,
            volumeSize: 100 * 1024 * 1024
        )
        XCTAssertTrue(capabilities(for: profile).contains(.createVolumes))
    }

    func testEncryptFileNamesRequestsCapability() {
        let profile = CompressionProfile(
            name: "7z encrypted",
            format: .sevenZip,
            level: .normal,
            encryptFileNames: true
        )
        XCTAssertTrue(capabilities(for: profile).contains(.encryptFileNames))
    }
}
