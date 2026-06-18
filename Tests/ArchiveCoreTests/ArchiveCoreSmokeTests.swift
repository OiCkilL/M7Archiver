import XCTest
@testable import ArchiveCore

final class ArchiveCoreSmokeTests: XCTestCase {
    func testProductName() {
        XCTAssertEqual(ArchiveCore.productName, "M7Archiver")
    }

    func testArchiveEntryDefaultsNameFromPath() {
        let entry = ArchiveEntry(path: "folder/file.txt", size: 10, packedSize: 8)

        XCTAssertEqual(entry.name, "file.txt")
        XCTAssertEqual(entry.size, 10)
        XCTAssertEqual(entry.packedSize, 8)
        XCTAssertFalse(entry.isDirectory)
    }

    func testCompressionProfileStoresAdvancedOptions() {
        let profile = CompressionProfile(
            name: "Encrypted 7z",
            format: .sevenZip,
            level: .ultra,
            method: "lzma2",
            solid: true,
            dictionarySize: 256 * 1024 * 1024,
            volumeSize: 100 * 1024 * 1024,
            encryptFileNames: true,
            ignoreRules: IgnoreRule.defaultMacOSRules,
            filenameEncoding: .utf8
        )

        XCTAssertEqual(profile.level.rawValue, 9)
        XCTAssertEqual(profile.volumeSize, 100 * 1024 * 1024)
        XCTAssertTrue(profile.encryptFileNames)
        XCTAssertEqual(profile.ignoreRules.count, 3)
    }

    func testCatalogLoadsRequiredFormats() {
        let catalog = ArchiveFormatCatalog.shared

        XCTAssertNotNil(catalog.definition(for: .sevenZip))
        XCTAssertNotNil(catalog.definition(for: .zip))
        XCTAssertNotNil(catalog.definition(for: .rar))
        XCTAssertNotNil(catalog.definition(for: .tarGzip))
        XCTAssertNotNil(catalog.definition(for: .zstd))
        XCTAssertNotNil(catalog.definition(for: .tarZstd))
    }

    func testArchiveTypeDetectorDetectsCompoundExtension() {
        let detector = ArchiveTypeDetector()

        XCTAssertEqual(detector.detectByExtension(fileName: "backup.tar.gz"), .tarGzip)
        XCTAssertEqual(detector.detectByExtension(fileName: "backup.tar.zst"), .tarZstd)
    }

    func testArchiveTypeDetectorDetectsSevenZipSplitVolumesByName() {
        let detector = ArchiveTypeDetector()

        XCTAssertEqual(detector.detectByExtension(fileName: "file.7z.001"), .sevenZip)
        XCTAssertEqual(detector.detectByExtension(fileName: "file.7z.099"), .sevenZip)
        XCTAssertNil(detector.detectByExtension(fileName: "file.zip.001"))
        XCTAssertEqual(
            ArchiveTypeDetector.primarySevenZipVolumeURL(for: URL(fileURLWithPath: "/tmp/file.7z.012")).path,
            "/tmp/file.7z.001"
        )
    }

    func testArchiveTypeDetectorDetects7zByMagic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        try Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let detector = ArchiveTypeDetector()

        XCTAssertEqual(try detector.detectByMagicNumber(fileURL: url), .sevenZip)
    }

    func testEngineSelectorUsesLibArchiveForZipListContents() throws {
        let selector = ArchiveEngineSelector()

        let engine = try selector.engineType(for: .zip, requestedCapabilities: [.listContents])

        XCTAssertEqual(engine, .libarchive)
    }

    func testEngineSelectorUsesLibArchiveForZipCreateWithMethodProfile() throws {
        let selector = ArchiveEngineSelector()

        let engine = try selector.engineType(for: .zip, requestedCapabilities: [.create])

        XCTAssertEqual(engine, .libarchive)
    }

    func testEngineSelectorUsesSevenZipForVolumeCreation() throws {
        let selector = ArchiveEngineSelector()

        let engine = try selector.engineType(for: .sevenZip, requestedCapabilities: [.createVolumes])

        XCTAssertEqual(engine, .sevenZip)
    }

    func testEngineSelectorRejectsRarCreateWithoutExternalRar() {
        let selector = ArchiveEngineSelector()

        XCTAssertThrowsError(try selector.engineType(for: .rar, requestedCapabilities: [.externalCreate])) { error in
            XCTAssertEqual(error as? ArchiveEngineSelectionError, .externalRarNotConfigured)
        }
    }

    func testEngineSelectorRejectsUnsupportedCreateCapabilities() {
        let selector = ArchiveEngineSelector()

        XCTAssertThrowsError(try selector.engineType(for: .tar, requestedCapabilities: [.create])) { error in
            XCTAssertEqual(error as? ArchiveEngineSelectionError, .unsupportedCapabilities([.create], .tar))
        }
    }

    func testArchivePathValidatorRejectsPathTraversal() {
        let destination = URL(fileURLWithPath: "/tmp/output", isDirectory: true)

        XCTAssertThrowsError(try ArchivePathValidator.validatedOutputURL(for: "../../evil", in: destination))
        XCTAssertThrowsError(try ArchivePathValidator.validatedOutputURL(for: "/tmp/evil", in: destination))
        XCTAssertNoThrow(try ArchivePathValidator.validatedOutputURL(for: "folder/file.txt", in: destination))
    }

    func testArchiveExtractionFinalizerStagingDirectoryIsBesideDestination() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let staging = try ArchiveExtractionFinalizer.makeStagingDirectory(for: destination)

        XCTAssertEqual(staging.deletingLastPathComponent().path, root.path)
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
    }

    func testArchiveExtractionFinalizerStagingDirectoryIsInsideExistingDestination() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let staging = try ArchiveExtractionFinalizer.makeStagingDirectory(for: destination)

        XCTAssertEqual(staging.deletingLastPathComponent().path, destination.path)
    }

    func testArchiveExtractionFinalizerMergesDirectoriesAndRejectsSymlinks() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("new".utf8).write(to: staging.appendingPathComponent("folder/new.txt"))
        try Data("keep".utf8).write(to: destination.appendingPathComponent("folder/keep.txt"))

        _ = try await ArchiveExtractionFinalizer.finalize(
            entries: [ArchiveEntry(path: "folder/new.txt")],
            from: staging,
            to: destination
        )

        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("folder/keep.txt")), encoding: .utf8), "keep")
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("folder/new.txt")), encoding: .utf8), "new")

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: destination.appendingPathComponent("link", isDirectory: true),
            withDestinationURL: outside
        )
        try fileManager.createDirectory(at: staging.appendingPathComponent("link", isDirectory: true), withIntermediateDirectories: true)
        try Data("escape".utf8).write(to: staging.appendingPathComponent("link/escape.txt"))

        do {
            _ = try await ArchiveExtractionFinalizer.finalize(
                entries: [ArchiveEntry(path: "link/escape.txt")],
                from: staging,
                to: destination
            )
            XCTFail("Expected unsafeDestinationPath error")
        } catch {
            XCTAssertEqual(error as? ArchiveExtractionFinalizationError, .unsafeDestinationPath("link/escape.txt"))
        }
    }

    func testArchiveExtractionFinalizerIgnoresDuplicateEntriesAfterFirstMove() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("duplicate".utf8).write(to: staging.appendingPathComponent("same.txt"))

        let outputURLs = try await ArchiveExtractionFinalizer.finalize(
            entries: [
                ArchiveEntry(path: "same.txt"),
                ArchiveEntry(path: "same.txt")
            ],
            from: staging,
            to: destination
        )

        XCTAssertEqual(outputURLs.map(\.lastPathComponent), ["same.txt"])
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("same.txt")), encoding: .utf8), "duplicate")
    }

    func testArchiveExtractionFinalizerRejectsDirectoryEntryCollidingWithFile() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("old".utf8).write(to: destination.appendingPathComponent("folder"))

        do {
            _ = try await ArchiveExtractionFinalizer.finalize(
                entries: [ArchiveEntry(path: "folder", isDirectory: true)],
                from: staging,
                to: destination
            )
            XCTFail("Expected unsafeDestinationPath error")
        } catch {
            XCTAssertEqual(error as? ArchiveExtractionFinalizationError, .unsafeDestinationPath("folder"))
        }

        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("folder")), encoding: .utf8), "old")
    }

    func testArchiveExtractionFinalizerRollsBackPreviousFileReplacementOnFailure() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: staging.appendingPathComponent("link", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("new".utf8).write(to: staging.appendingPathComponent("replace.txt"))
        try Data("old".utf8).write(to: destination.appendingPathComponent("replace.txt"))
        try Data("escape".utf8).write(to: staging.appendingPathComponent("link/escape.txt"))
        try fileManager.createSymbolicLink(
            at: destination.appendingPathComponent("link", isDirectory: true),
            withDestinationURL: outside
        )

        do {
            _ = try await ArchiveExtractionFinalizer.finalize(
                entries: [
                    ArchiveEntry(path: "replace.txt"),
                    ArchiveEntry(path: "link/escape.txt")
                ],
                from: staging,
                to: destination
            )
            XCTFail("Expected unsafeDestinationPath error")
        } catch {
            XCTAssertEqual(error as? ArchiveExtractionFinalizationError, .unsafeDestinationPath("link/escape.txt"))
        }

        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("replace.txt")), encoding: .utf8), "old")
    }

    func testFinalizeRenameStrategyProducesFinderStyleUniqueName() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("old".utf8).write(to: destination.appendingPathComponent("file.txt"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("file.txt"))

        _ = try await ArchiveExtractionFinalizer.finalize(
            entries: [ArchiveEntry(path: "file.txt")],
            from: staging,
            to: destination,
            conflictStrategy: .rename
        )

        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("file.txt")), encoding: .utf8), "old")
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("file 2.txt")), encoding: .utf8), "new")
    }

    func testFinalizeAskKeepBothMirrorsRename() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("old".utf8).write(to: destination.appendingPathComponent("file.txt"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("file.txt"))

        _ = try await ArchiveExtractionFinalizer.finalize(
            entries: [ArchiveEntry(path: "file.txt")],
            from: staging,
            to: destination,
            conflictStrategy: .ask,
            onConflict: { _ in .keepBoth }
        )

        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("file.txt")), encoding: .utf8), "old")
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("file 2.txt")), encoding: .utf8), "new")
    }

    func testFinalizeAskReplaceOverwritesExisting() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("old".utf8).write(to: destination.appendingPathComponent("file.txt"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("file.txt"))

        _ = try await ArchiveExtractionFinalizer.finalize(
            entries: [ArchiveEntry(path: "file.txt")],
            from: staging,
            to: destination,
            conflictStrategy: .ask,
            onConflict: { _ in .overwrite }
        )

        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("file.txt")), encoding: .utf8), "new")
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("file 2.txt").path))
    }

    func testFinalizeAskStopThrowsAndRollsBackPriorFiles() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("a".utf8).write(to: staging.appendingPathComponent("a.txt"))
        try Data("b-new".utf8).write(to: staging.appendingPathComponent("b.txt"))
        try Data("b-old".utf8).write(to: destination.appendingPathComponent("b.txt"))

        do {
            _ = try await ArchiveExtractionFinalizer.finalize(
                entries: [ArchiveEntry(path: "a.txt"), ArchiveEntry(path: "b.txt")],
                from: staging,
                to: destination,
                conflictStrategy: .ask,
                onConflict: { _ in .stop }
            )
            XCTFail("Expected userStoppedExtraction")
        } catch {
            XCTAssertEqual(error as? ArchiveExtractionFinalizationError, .userStoppedExtraction)
        }

        // First-moved file rolled back (removed); existing b.txt untouched.
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("b.txt")), encoding: .utf8), "b-old")
    }

    func testFinalizeAskWithoutCallbackThrows() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("old".utf8).write(to: destination.appendingPathComponent("file.txt"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("file.txt"))

        do {
            _ = try await ArchiveExtractionFinalizer.finalize(
                entries: [ArchiveEntry(path: "file.txt")],
                from: staging,
                to: destination,
                conflictStrategy: .ask
            )
            XCTFail("Expected throw when .ask strategy has no onConflict callback")
        } catch {
            // Any throw is acceptable; the guard maps it to unsafeDestinationPath.
            XCTAssertEqual(error as? ArchiveExtractionFinalizationError, .unsafeDestinationPath("file.txt"))
        }
    }

    func testFinalizeRenameStrategyRenamesCollidingDirectoryAndChildren() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging.appendingPathComponent("folder/sub", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("a".utf8).write(to: staging.appendingPathComponent("folder/a.txt"))
        try Data("b".utf8).write(to: staging.appendingPathComponent("folder/sub/b.txt"))

        _ = try await ArchiveExtractionFinalizer.finalize(
            entries: [
                ArchiveEntry(path: "folder", isDirectory: true),
                ArchiveEntry(path: "folder/a.txt"),
                ArchiveEntry(path: "folder/sub/b.txt")
            ],
            from: staging,
            to: destination,
            conflictStrategy: .rename
        )

        // Existing folder stays empty (untouched); new content under folder 2.
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("folder 2/a.txt").path))
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("folder 2/a.txt")), encoding: .utf8), "a")
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("folder 2/sub/b.txt").path))
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("folder 2/sub/b.txt")), encoding: .utf8), "b")
        // Original folder remains, empty (merged nothing).
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("folder").path))
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("folder/a.txt").path))
    }

    func testFinalizeAskKeepBothRenamesCollidingDirectory() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("new".utf8).write(to: staging.appendingPathComponent("folder/inside.txt"))

        _ = try await ArchiveExtractionFinalizer.finalize(
            entries: [
                ArchiveEntry(path: "folder", isDirectory: true),
                ArchiveEntry(path: "folder/inside.txt")
            ],
            from: staging,
            to: destination,
            conflictStrategy: .ask,
            onConflict: { _ in .keepBoth }
        )

        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("folder 2/inside.txt")), encoding: .utf8), "new")
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("folder/inside.txt").path))
    }

    func testFinalizeOverwriteStrategyMergesIntoExistingDirectory() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: staging.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination.appendingPathComponent("folder", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data("keep".utf8).write(to: destination.appendingPathComponent("folder/keep.txt"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("folder/new.txt"))

        _ = try await ArchiveExtractionFinalizer.finalize(
            entries: [
                ArchiveEntry(path: "folder", isDirectory: true),
                ArchiveEntry(path: "folder/new.txt")
            ],
            from: staging,
            to: destination,
            conflictStrategy: .overwrite
        )

        // Merged: existing keep.txt untouched, new.txt added alongside.
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("folder/keep.txt")), encoding: .utf8), "keep")
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("folder/new.txt")), encoding: .utf8), "new")
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("folder 2").path))
    }

    func testIgnoreRuleMatcherFiltersMacOSJunkFiles() {
        let matcher = IgnoreRuleMatcher(rules: IgnoreRule.defaultMacOSRules)

        XCTAssertTrue(matcher.shouldIgnore(URL(fileURLWithPath: "/tmp/.DS_Store")))
        XCTAssertTrue(matcher.shouldIgnore(URL(fileURLWithPath: "/tmp/._icon")))
        XCTAssertFalse(matcher.shouldIgnore(URL(fileURLWithPath: "/tmp/file.txt")))
    }

    func testBuiltInCompressionProfilesContainRequiredNames() {
        let names = Set(BuiltInCompressionProfiles.all.map(\ .name))

        XCTAssertTrue(names.contains("Fast ZIP"))
        XCTAssertTrue(names.contains("Standard 7z"))
        XCTAssertTrue(names.contains("Ultra 7z"))
        XCTAssertTrue(names.contains("Encrypted 7z"))
        XCTAssertTrue(names.contains("Split 100MB 7z"))
        XCTAssertTrue(names.contains("Windows-compatible ZIP"))
    }
}
