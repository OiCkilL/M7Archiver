import XCTest
import ArchiveCore
@testable import M7ArchiverApp

@MainActor
final class QuickCompressActionTests: XCTestCase {
    func testFixedProfileForZipUsesPlanDefaults() throws {
        let settings = try makeSettings(ignoreRules: [
            IgnoreRule(id: "trimmed", pattern: "  .DS_Store  ", isEnabled: true, scope: .files),
            IgnoreRule(id: "disabled", pattern: "*.tmp", isEnabled: false, scope: .files)
        ])

        let profile = QuickCompressAction.fixedProfile(format: .zip, settings: settings)

        XCTAssertEqual(profile.format, .zip)
        XCTAssertEqual(profile.level, .normal)
        XCTAssertNil(profile.method)
        XCTAssertNil(profile.solid)
        XCTAssertNil(profile.dictionarySize)
        XCTAssertNil(profile.volumeSize)
        XCTAssertFalse(profile.encryptFileNames)
        XCTAssertNil(profile.filenameEncoding)
        XCTAssertEqual(profile.ignoreRules.map(\.pattern), [".DS_Store"])
    }

    func testFixedProfileForSevenZipUsesPlanDefaults() throws {
        let settings = try makeSettings(ignoreRules: IgnoreRule.defaultMacOSRules)
        let profile = QuickCompressAction.fixedProfile(format: .sevenZip, settings: settings)

        XCTAssertEqual(profile.format, .sevenZip)
        XCTAssertEqual(profile.level, .normal)
        XCTAssertEqual(profile.method, "lzma2")
        XCTAssertEqual(profile.solid, true)
        XCTAssertNil(profile.dictionarySize)
        XCTAssertNil(profile.volumeSize)
        XCTAssertFalse(profile.encryptFileNames)
        XCTAssertNil(profile.filenameEncoding)
        XCTAssertEqual(profile.ignoreRules, CompressDialogView.enabledNormalizedIgnoreRules(from: IgnoreRule.defaultMacOSRules))
    }

    func testQuickActionDestinationForSingleFileUsesParentDirectory() {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        let destination = QuickCompressAction.quickActionDestination(sources: [file], finderTarget: nil, format: .zip)
        XCTAssertEqual(destination?.path, "/tmp/report.zip")
    }

    func testQuickActionDestinationForSingleFileIgnoresDifferentFinderTarget() {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        let target = URL(fileURLWithPath: "/tmp/output", isDirectory: true)
        let destination = QuickCompressAction.quickActionDestination(sources: [file], finderTarget: target, format: .zip)
        XCTAssertEqual(destination?.path, "/tmp/report.zip")
    }

    func testQuickActionDestinationForSingleFolderUsesParentDirectory() {
        let folder = URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)
        let destination = QuickCompressAction.quickActionDestination(sources: [folder], finderTarget: nil, format: .sevenZip)
        XCTAssertEqual(destination?.path, "/tmp/Folder.7z")
    }

    func testQuickActionDestinationIgnoresFinderTargetWhenItIsSelectedItem() {
        let folder = URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)
        let destination = QuickCompressAction.quickActionDestination(sources: [folder], finderTarget: folder, format: .zip)
        XCTAssertEqual(destination?.path, "/tmp/Folder.zip")
    }

    func testQuickActionDestinationPrefersFinderTargetForMultipleItems() {
        let sources = [
            URL(fileURLWithPath: "/tmp/a/file1.txt"),
            URL(fileURLWithPath: "/tmp/b/file2.txt")
        ]
        let target = URL(fileURLWithPath: "/tmp/output", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }

        let destination = QuickCompressAction.quickActionDestination(sources: sources, finderTarget: target, format: .zip)
        XCTAssertEqual(destination?.path, "/tmp/output/Archive.zip")
    }

    func testQuickActionDestinationFallsBackToCommonParent() {
        let sources = [
            URL(fileURLWithPath: "/tmp/Photos/a.jpg"),
            URL(fileURLWithPath: "/tmp/Photos/b.jpg")
        ]
        let destination = QuickCompressAction.quickActionDestination(sources: sources, finderTarget: nil, format: .zip)
        XCTAssertEqual(destination?.path, "/tmp/Photos/Photos.zip")
    }

    func testQuickActionDestinationReturnsNilForDisjointParentsWithoutFinderTarget() {
        let sources = [
            URL(fileURLWithPath: "/tmp/a/file1.txt"),
            URL(fileURLWithPath: "/tmp/b/file2.txt")
        ]
        XCTAssertNil(QuickCompressAction.quickActionDestination(sources: sources, finderTarget: nil, format: .zip))
    }

    func testIsUsableDestinationRejectsExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = dir.appendingPathComponent("Archive.zip")
        try Data().write(to: existing)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(QuickCompressAction.isUsableDestination(existing))
    }

    func testIsUsableDestinationRejectsMissingDirectory() {
        let destination = URL(fileURLWithPath: "/tmp/missing-dir-\(UUID().uuidString)/Archive.zip")
        XCTAssertFalse(QuickCompressAction.isUsableDestination(destination))
    }

    func testIsUsableDestinationAcceptsWritableNewPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(QuickCompressAction.isUsableDestination(dir.appendingPathComponent("Archive.zip")))
    }

    func testWritableDestinationDirectoryAcceptsExistingFileChosenFromSavePanel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = dir.appendingPathComponent("Archive.zip")
        try Data().write(to: existing)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(QuickCompressAction.isUsableDestination(existing))
        XCTAssertTrue(QuickCompressAction.isWritableDestinationDirectory(existing))
    }

    private func makeSettings(ignoreRules: [IgnoreRule]) throws -> ArchiveSettings {
        let suiteName = "QuickCompressActionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = ArchiveSettings(defaults: defaults)
        settings.ignoreRules = ignoreRules
        return settings
    }
}
