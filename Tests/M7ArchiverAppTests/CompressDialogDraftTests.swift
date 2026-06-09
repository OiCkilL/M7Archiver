import XCTest
import ArchiveCore
@testable import M7ArchiverApp

@MainActor
final class CompressDialogDraftTests: XCTestCase {
    // MARK: - Initial defaults

    func testDraftDefaultsToSevenZipNormalIgnoringLegacyProfileID() throws {
        let settings = try makeSettings(defaultProfileID: "ultra-7z")
        let draft = CompressDialogView.draft(for: settings)

        XCTAssertEqual(draft.format, .sevenZip)
        XCTAssertEqual(draft.level, .normal)
        XCTAssertTrue(draft.solid)
        XCTAssertFalse(draft.useEncryption)
        XCTAssertFalse(draft.saveInKeychain)
        XCTAssertEqual(draft.splitVolumeMB, "")
        XCTAssertEqual(settings.defaultEncoding, .automatic)
        XCTAssertEqual(draft.encoding, .utf8)
    }

    func testDraftCapturesEnabledNormalizedIgnoreRulesAndEnablesCheckboxByDefault() throws {
        let rules = [
            IgnoreRule(id: "dsstore", pattern: ".DS_Store", isEnabled: true, scope: .files),
            IgnoreRule(id: "macosx", pattern: "  __MACOSX  ", isEnabled: true, scope: .directories),
            IgnoreRule(id: "disabled", pattern: "*.tmp", isEnabled: false, scope: .files),
            IgnoreRule(id: "blank", pattern: "   ", isEnabled: true, scope: .all)
        ]
        let settings = try makeSettings()
        settings.ignoreRules = rules

        let draft = CompressDialogView.draft(for: settings)

        XCTAssertTrue(draft.applyDefaultIgnoreRules)
        XCTAssertEqual(draft.capturedIgnoreRules.map(\.pattern), [".DS_Store", "__MACOSX"])
    }

    func testDraftDisablesIgnoreCheckboxWhenNoEnabledRules() throws {
        let settings = try makeSettings()
        settings.ignoreRules = [
            IgnoreRule(id: "disabled", pattern: "*.tmp", isEnabled: false, scope: .files)
        ]

        let draft = CompressDialogView.draft(for: settings)

        XCTAssertFalse(draft.applyDefaultIgnoreRules)
        XCTAssertTrue(draft.capturedIgnoreRules.isEmpty)
    }

    // MARK: - Draft-to-profile mapping

    func testZipLevelMatrixUsesDraftLevelAndEngineDefaults() throws {
        let settings = try makeSettings()
        for level in CompressionLevel.allCases {
            var draft = CompressDialogView.draft(for: settings)
            draft.format = .zip
            draft.level = level
            draft.solid = true
            draft.splitVolumeMB = "100"
            draft.useEncryption = true
            draft.encryptFileNames = true
            draft.encoding = .big5

            let profile = CompressDialogView.makeProfile(from: draft)

            XCTAssertEqual(profile.format, .zip)
            XCTAssertEqual(profile.level, level, "level for \(level)")
            XCTAssertNil(profile.method)
            XCTAssertNil(profile.solid)
            XCTAssertNil(profile.dictionarySize)
            XCTAssertNil(profile.volumeSize)
            XCTAssertFalse(profile.encryptFileNames)
            XCTAssertEqual(profile.filenameEncoding, .big5)
        }
    }

    func testZipUltraFromDraftStillRoutesToLibarchive() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        draft.format = .zip
        draft.level = .ultra

        let profile = CompressDialogView.makeProfile(from: draft)
        let selector = ArchiveEngineSelector(externalRarConfigured: false)
        let engine = try selector.engineType(
            for: profile.format,
            requestedCapabilities: ArchiveCreationService.requestedCapabilities(for: profile)
        )

        XCTAssertEqual(profile.level, .ultra)
        XCTAssertEqual(engine, .libarchive)
    }

    func testSevenZipLevelMatrix() throws {
        let settings = try makeSettings()
        let cases: [(CompressionLevel, String?, Int64?)] = [
            (.store, nil, nil),
            (.fastest, "lzma2", nil),
            (.fast, "lzma2", nil),
            (.normal, "lzma2", nil),
            (.maximum, "lzma2", nil),
            (.ultra, "lzma2", 256 * 1024 * 1024)
        ]
        for (level, expectedMethod, expectedDict) in cases {
            var draft = CompressDialogView.draft(for: settings)
            draft.format = .sevenZip
            draft.level = level

            let profile = CompressDialogView.makeProfile(from: draft)

            XCTAssertEqual(profile.format, .sevenZip)
            XCTAssertEqual(profile.level, level, "level for \(level)")
            XCTAssertEqual(profile.method, expectedMethod, "method for \(level)")
            XCTAssertEqual(profile.dictionarySize, expectedDict, "dictionarySize for \(level)")
            XCTAssertEqual(profile.solid, true, "solid for \(level)")
            XCTAssertNil(profile.volumeSize, "volumeSize for \(level)")
        }
    }

    // MARK: - Split volume validation

    func testSplitVolumeValidationAcceptsEmptyAndPositiveIntegersOnly() {
        XCTAssertTrue(CompressDialogView.isValidSplitVolumeMB(""))
        XCTAssertTrue(CompressDialogView.isValidSplitVolumeMB("100"))
        XCTAssertTrue(CompressDialogView.isValidSplitVolumeMB(" 1024 "))
        XCTAssertFalse(CompressDialogView.isValidSplitVolumeMB("0"))
        XCTAssertFalse(CompressDialogView.isValidSplitVolumeMB("-1"))
        XCTAssertFalse(CompressDialogView.isValidSplitVolumeMB("700MB"))
        XCTAssertFalse(CompressDialogView.isValidSplitVolumeMB("9999999999999"))
    }

    func testSplitVolumeEmptyProducesNilVolumeSize() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        draft.format = .sevenZip
        draft.splitVolumeMB = ""

        XCTAssertNil(CompressDialogView.makeProfile(from: draft).volumeSize)
    }

    func testSplitVolumeValidValueProducesCorrectByteCount() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        draft.format = .sevenZip
        draft.splitVolumeMB = "100"

        XCTAssertEqual(CompressDialogView.makeProfile(from: draft).volumeSize, 100 * 1024 * 1024)
    }

    func testSplitVolumeIsIgnoredForZipFormat() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        draft.format = .zip
        draft.splitVolumeMB = "100"

        XCTAssertNil(CompressDialogView.makeProfile(from: draft).volumeSize)
    }

    // MARK: - Format-compatible encryption method switching

    func testFormatSwitchFromZipToSevenZipResetsZipCryptoToAes256() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        draft.format = .zip
        draft.method = .zipCrypto

        CompressDialogView.applyFormatChange(.sevenZip, to: &draft)

        XCTAssertEqual(draft.method, .aes256)
    }

    func testFormatSwitchFromZipToSevenZipResetsAes128ToAes256() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        draft.format = .zip
        draft.method = .aes128

        CompressDialogView.applyFormatChange(.sevenZip, to: &draft)

        XCTAssertEqual(draft.method, .aes256)
    }

    func testFormatSwitchFromSevenZipToZipPreservesAes256() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        draft.format = .sevenZip
        draft.method = .aes256

        CompressDialogView.applyFormatChange(.zip, to: &draft)

        XCTAssertEqual(draft.method, .aes256)
    }

    // MARK: - Ignore checkbox

    func testIgnoreCheckboxOffMakesFinalProfileIgnoreRulesEmpty() throws {
        let settings = try makeSettings()
        settings.ignoreRules = [IgnoreRule(id: "dsstore", pattern: ".DS_Store", scope: .files)]
        var draft = CompressDialogView.draft(for: settings)
        draft.applyDefaultIgnoreRules = false

        XCTAssertTrue(CompressDialogView.makeProfile(from: draft).ignoreRules.isEmpty)
    }

    func testIgnoreCheckboxOnUsesCapturedIgnoreRules() throws {
        let settings = try makeSettings()
        settings.ignoreRules = [IgnoreRule(id: "dsstore", pattern: ".DS_Store", scope: .files)]
        let draft = CompressDialogView.draft(for: settings)

        XCTAssertEqual(
            CompressDialogView.makeProfile(from: draft).ignoreRules,
            [IgnoreRule(id: "dsstore", pattern: ".DS_Store", isEnabled: true, scope: .files)]
        )
    }

    func testCapturedIgnoreRulesAreFrozenAtDialogOpen() throws {
        let settings = try makeSettings()
        settings.ignoreRules = [IgnoreRule(id: "dsstore", pattern: ".DS_Store", scope: .files)]
        let draft = CompressDialogView.draft(for: settings)

        settings.ignoreRules = []

        XCTAssertEqual(
            CompressDialogView.makeProfile(from: draft).ignoreRules.map(\.pattern),
            [".DS_Store"]
        )
    }

    // MARK: - Encryption / format interplay

    func testZipFinalProfileNeverEncryptsFileNames() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        CompressDialogView.applyEncryptionChange(true, to: &draft)
        CompressDialogView.applyFormatChange(.zip, to: &draft)

        let profile = CompressDialogView.makeProfile(from: draft)

        XCTAssertFalse(profile.encryptFileNames)
    }

    func testSevenZipFinalProfileEncryptsFileNamesWhenEncryptionOn() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        CompressDialogView.applyEncryptionChange(true, to: &draft)

        let profile = CompressDialogView.makeProfile(from: draft)

        XCTAssertTrue(profile.encryptFileNames)
    }

    func testTurningOffEncryptionClearsSaveInKeychain() throws {
        let settings = try makeSettings()
        var draft = CompressDialogView.draft(for: settings)
        CompressDialogView.applyEncryptionChange(true, to: &draft)
        draft.saveInKeychain = true

        CompressDialogView.applyEncryptionChange(false, to: &draft)

        XCTAssertFalse(draft.useEncryption)
        XCTAssertFalse(draft.saveInKeychain)
        XCTAssertFalse(draft.encryptFileNames)
    }

    // MARK: - Helpers

    private func makeSettings(
        defaultProfileID: String? = nil,
        defaultEncoding: ArchiveEncoding? = nil
    ) throws -> ArchiveSettings {
        let suiteName = "CompressDialogDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        if let defaultProfileID {
            defaults.set(defaultProfileID, forKey: "settings.defaultProfileID")
        }
        if let defaultEncoding {
            defaults.set(defaultEncoding.rawValue, forKey: "settings.defaultEncoding")
        }
        return ArchiveSettings(defaults: defaults)
    }
}
