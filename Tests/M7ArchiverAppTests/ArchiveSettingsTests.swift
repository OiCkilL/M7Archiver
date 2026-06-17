import XCTest
import ArchiveCore
@testable import M7ArchiverApp

@MainActor
final class ArchiveSettingsTests: XCTestCase {
    func testDefaultEncodingPriorityOrderMatchesProductSpec() {
        let defaults = makeDefaults()
        let settings = ArchiveSettings(defaults: defaults)

        XCTAssertEqual(settings.defaultEncoding, .automatic)
        XCTAssertEqual(
            settings.encodingPriorityOrder,
            [.shiftJIS, .eucKR, .big5, .gb18030, .cp437, .windows1252, .cp850]
        )
    }

    func testEncodingPriorityOrderPersistsAfterReordering() {
        let defaults = makeDefaults()
        let settings = ArchiveSettings(defaults: defaults)
        settings.moveEncodingPriorityDown(.shiftJIS)

        let reloaded = ArchiveSettings(defaults: defaults)
        XCTAssertEqual(reloaded.encodingPriorityOrder, settings.encodingPriorityOrder)
        XCTAssertEqual(reloaded.encodingPriorityOrder.prefix(2), [.eucKR, .shiftJIS])
    }

    func testEncodingPriorityOrderPersistsAfterMove() {
        let defaults = makeDefaults()
        let settings = ArchiveSettings(defaults: defaults)
        settings.moveEncodingPriority(from: IndexSet(integer: 0), to: 3)

        let reloaded = ArchiveSettings(defaults: defaults)
        XCTAssertEqual(reloaded.encodingPriorityOrder, [.eucKR, .big5, .shiftJIS, .gb18030, .cp437, .windows1252, .cp850])
    }

    func testEncodingPriorityOrderNormalizesLegacyDuplicatesAndMissingValues() throws {
        let defaults = makeDefaults()
        let legacy = [ArchiveEncoding.gb18030, .shiftJIS, .gb18030]
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "settings.encodingPriorityOrder")

        let settings = ArchiveSettings(defaults: defaults)

        XCTAssertEqual(settings.encodingPriorityOrder, [.gb18030, .shiftJIS, .eucKR, .big5, .cp437, .windows1252, .cp850])
    }

    func testEncodingPriorityOrderFallsBackForInvalidStoredData() {
        let defaults = makeDefaults()
        defaults.set(Data([0x00, 0xff]), forKey: "settings.encodingPriorityOrder")

        let settings = ArchiveSettings(defaults: defaults)

        XCTAssertEqual(settings.encodingPriorityOrder, ArchiveSettings.defaultEncodingPriorityOrder)
    }

    func testResetEncodingPriorityOrderRestoresDefaultOrder() {
        let defaults = makeDefaults()
        let settings = ArchiveSettings(defaults: defaults)
        settings.moveEncodingPriority(from: IndexSet(integer: 0), to: 3)

        settings.resetEncodingPriorityOrder()

        XCTAssertEqual(settings.encodingPriorityOrder, ArchiveSettings.defaultEncodingPriorityOrder)
    }

    func testDisabledAutomaticEncodingsAreExcludedAndPersisted() {
        let defaults = makeDefaults()
        let settings = ArchiveSettings(defaults: defaults)

        settings.setAutomaticEncoding(.cp437, isEnabled: false)
        settings.setAutomaticEncoding(.windows1252, isEnabled: false)

        XCTAssertFalse(settings.isAutomaticEncodingEnabled(.cp437))
        XCTAssertFalse(settings.isAutomaticEncodingEnabled(.windows1252))
        XCTAssertEqual(settings.automaticEncodingPriority, [.shiftJIS, .eucKR, .big5, .gb18030, .cp850])

        let reloaded = ArchiveSettings(defaults: defaults)
        XCTAssertFalse(reloaded.isAutomaticEncodingEnabled(.cp437))
        XCTAssertFalse(reloaded.isAutomaticEncodingEnabled(.windows1252))
        XCTAssertEqual(reloaded.automaticEncodingPriority, settings.automaticEncodingPriority)
    }

    func testResetAutomaticDetectionSettingsRestoresOrderAndEnabledState() {
        let defaults = makeDefaults()
        let settings = ArchiveSettings(defaults: defaults)
        settings.moveEncodingPriority(from: IndexSet(integer: 0), to: 3)
        settings.setAutomaticEncoding(.cp850, isEnabled: false)

        settings.resetAutomaticDetectionSettings()

        XCTAssertEqual(settings.encodingPriorityOrder, ArchiveSettings.defaultEncodingPriorityOrder)
        XCTAssertEqual(settings.automaticEncodingPriority, ArchiveSettings.defaultEncodingPriorityOrder)
        XCTAssertTrue(settings.isAutomaticEncodingEnabled(.cp850))
    }

    func testAutoExtractDestinationRoundTripsThroughDefaults() {
        let defaults = makeDefaults()
        let settings = ArchiveSettings(defaults: defaults)
        let bookmark = Data([0x4d, 0x37, 0x01, 0x02])

        settings.autoExtract = true
        settings.updateAutoExtractStrategy(.customBookmark)
        settings.setCustomAutoExtractBookmark(bookmark)
        settings.revealInFinderAfterExtract = false

        let reloaded = ArchiveSettings(defaults: defaults)
        XCTAssertTrue(reloaded.autoExtract)
        XCTAssertEqual(reloaded.autoExtractDestination.strategy, .customBookmark)
        XCTAssertEqual(reloaded.autoExtractDestination.customFolderBookmark, bookmark)
        XCTAssertFalse(reloaded.revealInFinderAfterExtract)
    }

    func testRevealInFinderAfterCreateDefaultsToTrueAndPersistsIndependently() {
        let defaults = makeDefaults()
        let initial = ArchiveSettings(defaults: defaults)
        XCTAssertTrue(initial.revealInFinderAfterCreate)
        XCTAssertTrue(initial.revealInFinderAfterExtract)

        initial.revealInFinderAfterCreate = false
        let reloaded = ArchiveSettings(defaults: defaults)
        XCTAssertFalse(reloaded.revealInFinderAfterCreate)
        XCTAssertTrue(reloaded.revealInFinderAfterExtract)
    }

    func testOpenArchiveAfterCreateDefaultsToTrueAndPersistsIndependently() {
        let defaults = makeDefaults()
        let initial = ArchiveSettings(defaults: defaults)
        XCTAssertTrue(initial.openArchiveAfterCreate)
        XCTAssertTrue(initial.revealInFinderAfterCreate)

        initial.openArchiveAfterCreate = false
        let reloaded = ArchiveSettings(defaults: defaults)
        XCTAssertFalse(reloaded.openArchiveAfterCreate)
        XCTAssertTrue(reloaded.revealInFinderAfterCreate)
    }

    func testRestoreDefaultIgnoreRulesResetsCustomChanges() {
        let defaults = makeDefaults()
        let settings = ArchiveSettings(defaults: defaults)
        settings.ignoreRules = [IgnoreRule(id: "temp", pattern: "*.tmp", isEnabled: false, scope: .files)]

        settings.restoreDefaultIgnoreRules()

        let reloaded = ArchiveSettings(defaults: defaults)
        XCTAssertEqual(settings.ignoreRules, IgnoreRule.defaultMacOSRules)
        XCTAssertEqual(reloaded.ignoreRules, IgnoreRule.defaultMacOSRules)
    }

    func testIgnoreRuleDraftNormalizationRejectsWhitespaceOnlyRules() {
        let rules = IgnoreRulesDraft.normalized([
            IgnoreRule(id: "empty", pattern: "   ", scope: .all),
            IgnoreRule(id: "trim", pattern: "  *.tmp  ", scope: .files)
        ])

        XCTAssertEqual(rules, [IgnoreRule(id: "trim", pattern: "*.tmp", scope: .files)])
    }

    // MARK: - defaultProfileID is inert for the new create flow

    func testLegacyDefaultProfileIDIsIgnoredByDialogDraftDefaults() {
        let defaults = makeDefaults()
        defaults.set("ultra-7z", forKey: "settings.defaultProfileID")
        let settings = ArchiveSettings(defaults: defaults)
        let view = CompressDialogView(settings: settings)
        let profile = view.makeProfile()

        XCTAssertEqual(profile.format, .sevenZip)
        XCTAssertEqual(profile.level, .normal)
        XCTAssertEqual(profile.method, "lzma2")
        XCTAssertNil(profile.dictionarySize)
    }

    func testArchiveSettingsStillLoadsLegacyDefaultProfileIDForBackwardCompat() {
        let defaults = makeDefaults()
        defaults.set("ultra-7z", forKey: "settings.defaultProfileID")
        let settings = ArchiveSettings(defaults: defaults)
        XCTAssertEqual(settings.defaultProfileID, "ultra-7z")
    }

    private func makeDefaults(
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) -> UserDefaults {
        let suiteName = "ArchiveSettingsTests.\(file).\(function).\(line).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
