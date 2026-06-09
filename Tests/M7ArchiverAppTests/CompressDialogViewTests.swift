import XCTest
import ArchiveCore
@testable import M7ArchiverApp

@MainActor
final class CompressDialogViewTests: XCTestCase {
    func testIgnoredItemsSummaryShowsSinglePattern() {
        let rules = [IgnoreRule(id: "dsstore", pattern: ".DS_Store", scope: .files)]

        XCTAssertEqual(CompressDialogView.ignoredItemsSummary(for: rules), "Ignore “.DS_Store”")
    }

    func testIgnoredItemsSummaryShowsTwoPatterns() {
        let rules = [
            IgnoreRule(id: "dsstore", pattern: ".DS_Store", scope: .files),
            IgnoreRule(id: "macosx", pattern: "__MACOSX", scope: .directories)
        ]

        XCTAssertEqual(CompressDialogView.ignoredItemsSummary(for: rules), "Ignore “.DS_Store”, “__MACOSX”")
    }

    func testIgnoredItemsSummaryAddsEllipsisForMoreThanTwoPatterns() {
        let rules = [
            IgnoreRule(id: "dsstore", pattern: ".DS_Store", scope: .files),
            IgnoreRule(id: "macosx", pattern: "__MACOSX", scope: .directories),
            IgnoreRule(id: "resourceFork", pattern: "._*", scope: .files)
        ]

        XCTAssertEqual(CompressDialogView.ignoredItemsSummary(for: rules), "Ignore “.DS_Store”, “__MACOSX”, …")
    }

    func testDefaultMacOSIgnoreSummaryMatchesDialogCopy() {
        XCTAssertEqual(
            CompressDialogView.ignoredItemsSummary(for: IgnoreRule.defaultMacOSRules),
            "Ignore “.DS_Store”, “__MACOSX”, …"
        )
    }

    func testSevenZipOnlyControlsAreVisibleOnlyForSevenZip() {
        XCTAssertTrue(CompressDialogView.showsSevenZipOnlyControls(for: .sevenZip))
        XCTAssertFalse(CompressDialogView.showsSevenZipOnlyControls(for: .zip))
    }

    func testCompressionLevelControlIsVisibleForZipAndSevenZip() {
        XCTAssertTrue(CompressDialogView.showsCompressionLevelControl(for: .zip))
        XCTAssertTrue(CompressDialogView.showsCompressionLevelControl(for: .sevenZip))
    }

    func testSplitControlsAreVisibleOnlyForSevenZip() {
        XCTAssertTrue(CompressDialogView.showsSplitVolumeControls(for: .sevenZip))
        XCTAssertFalse(CompressDialogView.showsSplitVolumeControls(for: .zip))
    }

    func testSolidControlIsVisibleOnlyForSevenZip() {
        XCTAssertTrue(CompressDialogView.showsSolidControl(for: .sevenZip))
        XCTAssertFalse(CompressDialogView.showsSolidControl(for: .zip))
    }

    func testFilenameEncodingControlIsVisibleOnlyForZip() {
        XCTAssertTrue(CompressDialogView.showsFilenameEncodingControl(for: .zip))
        XCTAssertFalse(CompressDialogView.showsFilenameEncodingControl(for: .sevenZip))
    }

    func testZipShowsEditableEncryptionMethodPicker() {
        XCTAssertTrue(CompressDialogView.showsEditableEncryptionMethodPicker(for: .zip))
        XCTAssertFalse(CompressDialogView.showsEditableEncryptionMethodPicker(for: .sevenZip))
    }

    func testSevenZipShowsFixedAes256Method() {
        XCTAssertFalse(CompressDialogView.showsFixedEncryptionMethod(for: .zip))
        XCTAssertTrue(CompressDialogView.showsFixedEncryptionMethod(for: .sevenZip))
    }

    func testEncryptFileNamesControlRequiresSevenZipAndEncryption() throws {
        var draft = CompressDialogView.draft(for: try makeSettings())
        XCTAssertFalse(CompressDialogView.showsEncryptFileNamesControl(for: draft))

        draft.useEncryption = true
        draft.format = .zip
        XCTAssertFalse(CompressDialogView.showsEncryptFileNamesControl(for: draft))

        draft.format = .sevenZip
        XCTAssertTrue(CompressDialogView.showsEncryptFileNamesControl(for: draft))
    }

    func testSaveInKeychainControlRequiresEncryption() throws {
        var draft = CompressDialogView.draft(for: try makeSettings())
        XCTAssertFalse(CompressDialogView.showsSaveInKeychain(for: draft))

        draft.useEncryption = true
        XCTAssertTrue(CompressDialogView.showsSaveInKeychain(for: draft))
    }

    func testCompressionLevelSliderMappingsCoverAllLevels() {
        let expected: [CompressionLevel] = [.store, .fastest, .fast, .normal, .maximum, .ultra]
        let actual = expected.indices.map { index in
            CompressDialogView.compressionLevel(forSliderValue: Double(index))
        }
        XCTAssertEqual(actual, expected)

        for (index, level) in expected.enumerated() {
            XCTAssertEqual(CompressDialogView.compressionLevelIndex(for: level), index)
        }
    }

    func testCompressionLevelSliderMappingClampsOutOfRangeValues() {
        XCTAssertEqual(CompressDialogView.compressionLevel(forSliderValue: -10), .store)
        XCTAssertEqual(CompressDialogView.compressionLevel(forSliderValue: 99), .ultra)
    }

    func testCreateEnabledForDefaultDraft() throws {
        let draft = CompressDialogView.draft(for: try makeSettings())

        XCTAssertTrue(CompressDialogView.canCreateArchive(with: draft))
    }

    func testCreateDisabledForInvalidSevenZipSplit() throws {
        var draft = CompressDialogView.draft(for: try makeSettings())
        draft.format = .sevenZip
        draft.splitVolumeMB = "0"

        XCTAssertFalse(CompressDialogView.canCreateArchive(with: draft))
    }

    func testInvalidSplitDoesNotDisableZipCreate() throws {
        var draft = CompressDialogView.draft(for: try makeSettings())
        draft.format = .zip
        draft.splitVolumeMB = "0"

        XCTAssertTrue(CompressDialogView.canCreateArchive(with: draft))
    }

    func testCreateDisabledForEmptyPasswordWhenEncryptionEnabled() throws {
        var draft = CompressDialogView.draft(for: try makeSettings())
        draft.useEncryption = true
        draft.password = ""
        draft.confirm = ""

        XCTAssertFalse(CompressDialogView.canCreateArchive(with: draft))
    }

    func testCreateDisabledForPasswordMismatch() throws {
        var draft = CompressDialogView.draft(for: try makeSettings())
        draft.useEncryption = true
        draft.password = "secret"
        draft.confirm = "different"

        XCTAssertFalse(CompressDialogView.canCreateArchive(with: draft))
    }

    func testCreateEnabledForMatchingPasswordWhenEncryptionEnabled() throws {
        var draft = CompressDialogView.draft(for: try makeSettings())
        draft.useEncryption = true
        draft.password = "secret"
        draft.confirm = "secret"

        XCTAssertTrue(CompressDialogView.canCreateArchive(with: draft))
    }

    func testCreateDisabledForUnsupportedEncryptionMethodOnFormat() throws {
        var draft = CompressDialogView.draft(for: try makeSettings())
        draft.useEncryption = true
        draft.format = .sevenZip
        draft.method = .zipCrypto
        draft.password = "secret"
        draft.confirm = "secret"

        XCTAssertFalse(CompressDialogView.canCreateArchive(with: draft))
    }

    func testOpenCompressionSettingsClosureCanBeInjected() throws {
        var didOpenSettings = false
        let view = CompressDialogView(
            settings: try makeSettings(),
            onOpenCompressionSettings: { didOpenSettings = true }
        )

        view.onOpenCompressionSettings?()

        XCTAssertTrue(didOpenSettings)
    }

    private func makeSettings() throws -> ArchiveSettings {
        let suiteName = "CompressDialogViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return ArchiveSettings(defaults: defaults)
    }
}
