import XCTest
import Foundation
import Darwin
import CSevenZipBridge
@testable import ArchiveCore

final class SevenZipEngineTests: XCTestCase {
    private let executableURL = URL(fileURLWithPath: "/tmp/m7-fake-7zz")

    private func makeRunner(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        capturedArguments: ArgumentRecorder = ArgumentRecorder()
    ) -> SevenZipRunner {
        let recorder = capturedArguments
        return { _, args, stdin in
            recorder.append(args, stdin: stdin)
            return SevenZipProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
        }
    }

    private func makeStubEngine(
        runner: @escaping SevenZipRunner = { _, _, _ in SevenZipProcessResult(exitCode: 0, stdout: "", stderr: "") },
        listBridge: @escaping @Sendable (String) -> M7SevenZipEntryList = { _ in BridgeFixture.makeList(entries: []) },
        testBridge: (@Sendable (String) -> M7SevenZipEntryList)? = nil,
        extractBridge: @escaping @Sendable (String, String, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<M7SevenZipExtractProgress>?) -> Int32 = { _, _, _, _ in 0 }
    ) -> SevenZipEngine {
        let path = executableURL.path
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        return SevenZipEngine(
            executableURL: executableURL,
            runner: runner,
            listBridge: listBridge,
            testBridge: testBridge ?? listBridge,
            extractBridge: extractBridge,
            freeEntryList: BridgeFixture.freeList,
            freeCString: { ptr in if let ptr { free(ptr) } }
        )
    }

    // MARK: - List

    func testListContentsMapsBridgeEntries() async throws {
        let engine = makeStubEngine(
            listBridge: { _ in
                BridgeFixture.makeList(entries: [
                    BridgeFixture.entry(path: "readme.txt", size: 100, modifiedAt: 1_704_153_600)
                ])
            }
        )

        let entries = try await engine.listContents(of: URL(fileURLWithPath: "/tmp/foo.7z"))
        XCTAssertEqual(entries.map { $0.path }, ["readme.txt"])
        XCTAssertEqual(entries.first?.size, 100)
        XCTAssertNil(entries.first?.packedSize)
    }

    // MARK: - Metadata

    func testMetadataPopulatesArchiveFieldsFromBridgeEntries() async throws {
        let engine = makeStubEngine(
            listBridge: { _ in
                BridgeFixture.makeList(
                    entries: [BridgeFixture.entry(path: "readme.txt", size: 100, isEncrypted: true)],
                    isEncrypted: true
                )
            }
        )

        let metadata = try await engine.metadata(of: URL(fileURLWithPath: "/tmp/sample.7z"))
        XCTAssertEqual(metadata.format, ArchiveFormat.sevenZip)
        XCTAssertEqual(metadata.entriesCount, 1)
        XCTAssertEqual(metadata.uncompressedSize, 100)
        XCTAssertNil(metadata.compressedSize)
        XCTAssertTrue(metadata.isEncrypted)
        XCTAssertFalse(metadata.isMultiVolume)
    }

    func testMetadataSurfacesHeaderEncryptionAsIsEncrypted() async throws {
        let engine = makeStubEngine(
            listBridge: { _ in
                BridgeFixture.makeList(entries: [], error: "ERROR: Wrong password : foo.7z")
            }
        )

        let metadata = try await engine.metadata(of: URL(fileURLWithPath: "/tmp/foo.7z"))
        XCTAssertEqual(metadata.format, ArchiveFormat.sevenZip)
        XCTAssertTrue(metadata.isEncrypted)
        XCTAssertNil(metadata.entriesCount)
    }

    func testMetadataTreatsEncryptedSplitVolumeFallbackAsLocked() async throws {
        let engine = makeStubEngine(
            runner: makeRunner(
                stderr: "ERROR: /tmp/foo.7z.001 : Cannot open encrypted archive. Wrong password?",
                exitCode: 2
            ),
            listBridge: { _ in
                BridgeFixture.makeList(entries: [], error: "Unexpected end of 7-Zip input stream")
            }
        )

        let metadata = try await engine.metadata(of: URL(fileURLWithPath: "/tmp/foo.7z.001"))
        XCTAssertEqual(metadata.format, ArchiveFormat.sevenZip)
        XCTAssertTrue(metadata.isEncrypted)
        XCTAssertTrue(metadata.isMultiVolume)
        XCTAssertNil(metadata.entriesCount)
    }

    func testMetadataPropagatesNonEncryptionFailures() async {
        let engine = makeStubEngine(
            listBridge: { _ in
                BridgeFixture.makeList(entries: [], error: "ERROR: corrupt archive")
            }
        )

        do {
            _ = try await engine.metadata(of: URL(fileURLWithPath: "/tmp/foo.7z"))
            XCTFail("Expected processFailed")
        } catch let error as SevenZipEngineError {
            if case .processFailed(let code, let stderr) = error {
                XCTAssertEqual(code, 11)
                XCTAssertEqual(stderr, "ERROR: corrupt archive")
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Test

    func testTestArchiveFailsLoudlyOnBridgeError() async {
        let engine = makeStubEngine(
            testBridge: { _ in
                BridgeFixture.makeList(entries: [], error: "ERROR: bad")
            }
        )
        do {
            _ = try await engine.testArchive(URL(fileURLWithPath: "/tmp/foo.7z"))
            XCTFail("expected failure")
        } catch let error as SevenZipEngineError {
            if case .processFailed = error {
                // ok
            } else {
                XCTFail("unexpected: \(error)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - Extract

    func testExtractUsesBridgeAndReturnsMappedEntries() async throws {
        let recorder = ExtractRecorder()
        let engine = makeStubEngine(
            listBridge: { _ in
                BridgeFixture.makeList(entries: [BridgeFixture.entry(path: "readme.txt", size: 100)])
            },
            extractBridge: { archive, destination, _, _ in
                recorder.archivePath = archive
                recorder.destinationPath = destination
                return 0
            }
        )

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = try await engine.extract(URL(fileURLWithPath: "/tmp/foo.7z"), to: dest)
        XCTAssertEqual(recorder.archivePath, "/tmp/foo.7z")
        XCTAssertNotEqual(recorder.destinationPath, dest.path)
        XCTAssertEqual(result.entries.map { $0.path }, ["readme.txt"])
    }

    func testExtractRejectsPathTraversalEntries() async {
        let engine = makeStubEngine(
            listBridge: { _ in
                BridgeFixture.makeList(entries: [BridgeFixture.entry(path: "../../etc/passwd", size: 1)])
            }
        )
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        do {
            _ = try await engine.extract(URL(fileURLWithPath: "/tmp/foo.7z"), to: dest)
            XCTFail("Expected path-traversal rejection")
        } catch {
            // ok — ArchivePathValidator threw
        }
    }

    func testExtractRejectsSymlinkDestinationComponents() async throws {
        let recorder = ExtractRecorder()
        let engine = makeStubEngine(
            listBridge: { _ in
                BridgeFixture.makeList(entries: [BridgeFixture.entry(path: "readme.txt", size: 100)])
            },
            extractBridge: { _, destination, _, _ in
                recorder.destinationPath = destination
                let output = URL(fileURLWithPath: destination).appendingPathComponent("readme.txt")
                FileManager.default.createFile(atPath: output.path, contents: Data("payload".utf8))
                return 0
            }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = root.appendingPathComponent("out", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: dest.appendingPathComponent("readme.txt"),
            withDestinationURL: outside.appendingPathComponent("readme.txt")
        )

        do {
            _ = try await engine.extract(URL(fileURLWithPath: "/tmp/foo.7z"), to: dest)
            XCTFail("Expected symlink destination rejection")
        } catch ArchiveExtractionFinalizationError.unsafeDestinationPath("readme.txt") {
            XCTAssertNotEqual(recorder.destinationPath, dest.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Create

    func testCreateBuildsArgumentsForSevenZipProfile() async throws {
        let recorder = ArgumentRecorder()
        let engine = makeStubEngine(runner: makeRunner(capturedArguments: recorder))

        let profile = CompressionProfile(
            name: "Custom 7z",
            format: .sevenZip,
            level: .maximum,
            method: "lzma2",
            solid: true,
            dictionarySize: 64 * 1024 * 1024,
            volumeSize: nil,
            encryptFileNames: false,
            ignoreRules: []
        )

        let archive = URL(fileURLWithPath: "/tmp/out.7z")
        let sources = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]

        _ = try await engine.createArchive(from: sources, to: archive, profile: profile)

        let args = try XCTUnwrap(recorder.lastArguments)
        XCTAssertEqual(args.first, "a")
        XCTAssertTrue(args.contains("-y"))
        XCTAssertTrue(args.contains("-t7z"))
        XCTAssertTrue(args.contains("-mx7"))
        XCTAssertTrue(args.contains("-ms=on"))
        XCTAssertTrue(args.contains("-md=64m"))
        XCTAssertTrue(args.contains("-m0=lzma2"))
        XCTAssertEqual(args.suffix(3), ["/tmp/out.7z", "/tmp/a.txt", "/tmp/b.txt"])
        XCTAssertFalse(args.contains("-p"))
        XCTAssertNil(recorder.lastStdin)
    }

    func testCreatePassesPasswordOnStdinWithoutPuttingSecretInArguments() async throws {
        let recorder = ArgumentRecorder()
        let engine = makeStubEngine(runner: makeRunner(capturedArguments: recorder))
        let profile = CompressionProfile(name: "Encrypted 7z", format: .sevenZip)

        _ = try await engine.createArchive(
            from: [URL(fileURLWithPath: "/tmp/a.txt")],
            to: URL(fileURLWithPath: "/tmp/o.7z"),
            profile: profile,
            password: "s3cret"
        )

        let args = try XCTUnwrap(recorder.lastArguments)
        XCTAssertTrue(args.contains("-p"))
        XCTAssertFalse(args.contains { $0.contains("s3cret") })
        XCTAssertEqual(recorder.lastStdin, "s3cret\n")
    }

    func testCreateMapsEncryptedFileNamesToHeaderEncryptionWhenPasswordIsPresent() async throws {
        let recorder = ArgumentRecorder()
        let engine = makeStubEngine(runner: makeRunner(capturedArguments: recorder))
        let profile = CompressionProfile(
            name: "Header Encrypted 7z",
            format: .sevenZip,
            encryptFileNames: true
        )

        _ = try await engine.createArchive(
            from: [URL(fileURLWithPath: "/tmp/a.txt")],
            to: URL(fileURLWithPath: "/tmp/o.7z"),
            profile: profile,
            password: "s3cret"
        )

        let args = try XCTUnwrap(recorder.lastArguments)
        XCTAssertTrue(args.contains("-mhe=on"))
        XCTAssertTrue(args.contains("-p"))
        XCTAssertEqual(recorder.lastStdin, "s3cret\n")
    }

    func testCreateRefusesEncryptedFileNamesWithoutPassword() async {
        let engine = makeStubEngine()
        let profile = CompressionProfile(
            name: "Encrypted",
            format: .sevenZip,
            encryptFileNames: true
        )

        do {
            _ = try await engine.createArchive(
                from: [URL(fileURLWithPath: "/tmp/a.txt")],
                to: URL(fileURLWithPath: "/tmp/o.7z"),
                profile: profile
            )
            XCTFail("Expected unsupportedEncryption")
        } catch SevenZipEngineError.unsupportedEncryption {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateRejectsUnsupportedFormat() async {
        let engine = makeStubEngine()
        let profile = CompressionProfile(name: "Tar via 7zz", format: .tarGzip)

        do {
            _ = try await engine.createArchive(
                from: [URL(fileURLWithPath: "/tmp/a.txt")],
                to: URL(fileURLWithPath: "/tmp/o.tar.gz"),
                profile: profile
            )
            XCTFail("Expected unsupportedFormat")
        } catch SevenZipEngineError.unsupportedFormat(let format) {
            XCTAssertEqual(format, .tarGzip)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreatePassesIgnoreRulesAsRecursiveExcludes() async throws {
        let recorder = ArgumentRecorder()
        let engine = makeStubEngine(runner: makeRunner(capturedArguments: recorder))
        let profile = CompressionProfile(
            name: "Standard 7z",
            format: .sevenZip,
            ignoreRules: IgnoreRule.defaultMacOSRules
        )

        _ = try await engine.createArchive(
            from: [URL(fileURLWithPath: "/tmp/folder")],
            to: URL(fileURLWithPath: "/tmp/o.7z"),
            profile: profile
        )

        let args = try XCTUnwrap(recorder.lastArguments)
        XCTAssertTrue(args.contains("-xr!.DS_Store"))
        XCTAssertTrue(args.contains("-xr!__MACOSX/"))
        XCTAssertTrue(args.contains("-xr!._*"))
    }

    func testCreateSkipsBlankAndDisabledIgnoreRules() async throws {
        let recorder = ArgumentRecorder()
        let engine = makeStubEngine(runner: makeRunner(capturedArguments: recorder))
        let profile = CompressionProfile(
            name: "Standard 7z",
            format: .sevenZip,
            ignoreRules: [
                IgnoreRule(pattern: ""),
                IgnoreRule(pattern: "*.tmp", isEnabled: false),
                IgnoreRule(pattern: "file-only", scope: .files),
                IgnoreRule(pattern: "keep", scope: .all)
            ]
        )

        _ = try await engine.createArchive(
            from: [URL(fileURLWithPath: "/tmp/folder")],
            to: URL(fileURLWithPath: "/tmp/o.7z"),
            profile: profile
        )

        let args = try XCTUnwrap(recorder.lastArguments)
        XCTAssertFalse(args.contains("-xr!"))
        XCTAssertFalse(args.contains("-xr!*.tmp"))
        XCTAssertTrue(args.contains("-xr!file-only"))
        XCTAssertTrue(args.contains("-xr!keep"))
    }

    func testCreateFailsWhenIgnoreRulesRemoveEverySource() async throws {
        let recorder = ArgumentRecorder()
        let engine = makeStubEngine(runner: makeRunner(capturedArguments: recorder))
        let profile = CompressionProfile(name: "Standard 7z", format: .sevenZip, ignoreRules: IgnoreRule.defaultMacOSRules)

        do {
            _ = try await engine.createArchive(
                from: [URL(fileURLWithPath: "/tmp/.DS_Store")],
                to: URL(fileURLWithPath: "/tmp/o.7z"),
                profile: profile
            )
            XCTFail("Expected missingSources")
        } catch SevenZipEngineError.missingSources {
            XCTAssertNil(recorder.lastArguments)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Binary missing

    func testCreateThrowsBinaryNotFoundWhenExecutableMissing() async {
        let engine = SevenZipEngine(
            executableURL: URL(fileURLWithPath: "/no/such/binary"),
            runner: makeRunner(),
            listBridge: { _ in BridgeFixture.makeList(entries: []) },
            testBridge: { _ in BridgeFixture.makeList(entries: []) },
            extractBridge: { _, _, _, _ in 0 },
            freeEntryList: BridgeFixture.freeList,
            freeCString: { ptr in if let ptr { free(ptr) } }
        )
        do {
            _ = try await engine.createArchive(
                from: [URL(fileURLWithPath: "/tmp/a.txt")],
                to: URL(fileURLWithPath: "/tmp/o.7z"),
                profile: CompressionProfile(name: "Standard 7z", format: .sevenZip)
            )
            XCTFail("Expected binaryNotFound")
        } catch SevenZipEngineError.binaryNotFound {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Helpers

final class ArgumentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(arguments: [String], stdin: String?)] = []

    func append(_ arguments: [String], stdin: String?) {
        lock.lock(); defer { lock.unlock() }
        calls.append((arguments, stdin))
    }

    var allArguments: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.arguments)
    }

    var lastArguments: [String]? {
        lock.lock(); defer { lock.unlock() }
        return calls.last?.arguments
    }

    var lastStdin: String? {
        lock.lock(); defer { lock.unlock() }
        return calls.last?.stdin
    }
}

final class ExtractRecorder: @unchecked Sendable {
    var archivePath: String?
    var destinationPath: String?
}

enum BridgeFixture {
    static func entry(
        path: String,
        size: Int64 = 0,
        modifiedAt: Int64 = -1,
        isDirectory: Bool = false,
        isEncrypted: Bool = false
    ) -> M7SevenZipEntry {
        M7SevenZipEntry(
            path: strdup(path),
            size: size,
            modifiedAt: modifiedAt,
            isDirectory: isDirectory,
            isEncrypted: isEncrypted
        )
    }

    static func makeList(
        entries: [M7SevenZipEntry],
        isEncrypted: Bool = false,
        error: String? = nil
    ) -> M7SevenZipEntryList {
        let pointer: UnsafeMutablePointer<M7SevenZipEntry>?
        if entries.isEmpty {
            pointer = nil
        } else {
            let buffer = UnsafeMutablePointer<M7SevenZipEntry>.allocate(capacity: entries.count)
            buffer.initialize(from: entries, count: entries.count)
            pointer = buffer
        }
        let errorPointer: UnsafeMutablePointer<CChar>? = error.map { strdup($0) }
        return M7SevenZipEntryList(
            entries: pointer,
            count: Int32(entries.count),
            isEncrypted: isEncrypted,
            error: errorPointer
        )
    }

    static func freeList(_ list: M7SevenZipEntryList) {
        if let entries = list.entries {
            let count = Int(list.count)
            for index in 0..<count {
                free(entries[index].path)
            }
            entries.deinitialize(count: count)
            entries.deallocate()
        }
        if let error = list.error {
            free(error)
        }
    }
}
