import Foundation
import XCTest
@testable import ArchiveCore

final class LibArchiveEngineTests: XCTestCase {
    func testAutoDetectBig5Encoding() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let content = directory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: content)
        let archiveURL = directory.appendingPathComponent("big5.zip")

        // Use Python to create a ZIP with a Big5-encoded filename.
        // Python's zipfile with force_zip64=False and strict encoding lets us
        // write raw Big5 bytes as the archive entry name.
        // Encode as Big5 bytes via Python
        let big5Name = "TV\u{7248}/\u{7E41}\u{9AD4}\u{6A94}\u{6848}/hello.txt"  // TV版/繁體檔案/hello.txt
        let rawScript = """
        import struct, zlib, sys
        name = sys.argv[1].encode('big5')
        data = open(sys.argv[2], 'rb').read()
        crc = zlib.crc32(data) & 0xFFFFFFFF
        name_len = len(name)
        data_len = len(data)

        def le32(v): return struct.pack('<I', v)
        def le16(v): return struct.pack('<H', v)

        out = open(sys.argv[3], 'wb')
        # Local file header (bit 11 clear = no UTF-8)
        sig1 = bytes([0x50, 0x4B, 0x03, 0x04])
        out.write(sig1 + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                  + le32(crc) + le32(data_len) + le32(data_len) + le16(name_len) + le16(0)
                  + name + data)
        lfh_end = out.tell()
        # Central directory
        sig2 = bytes([0x50, 0x4B, 0x01, 0x02])
        out.write(sig2 + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                  + le32(crc) + le32(data_len) + le32(data_len) + le16(name_len) + le16(0)
                  + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + name)
        cd_end = out.tell()
        cd_size = cd_end - lfh_end
        # EOCD
        sig3 = bytes([0x50, 0x4B, 0x05, 0x06])
        out.write(sig3 + le16(0) + le16(0) + le16(1) + le16(1)
                  + le32(cd_size) + le32(lfh_end) + le16(0))
        out.close()
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", rawScript, big5Name, content.path, archiveURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Python ZIP creation failed")

        let engine = LibArchiveEngine()
        let options = ArchiveOperationOptions(encoding: nil)
        let entries = try await engine.listContents(of: archiveURL, options: options)
        let meta = try await engine.metadata(of: archiveURL, options: options)

        XCTAssertEqual(entries.count, 1, "Should list the one entry")
        XCTAssertEqual(entries.first?.path, "TV版/繁體檔案/hello.txt", "Big5 filename should decode correctly, got '\(entries.first?.path ?? "")'")
        XCTAssertEqual(meta.encoding, .big5, "Should detect Big5 encoding, got \(String(describing: meta.encoding))")
    }

    func testAutoDetectRepositoryFilenameEncodingFixtures() async throws {
        let engine = LibArchiveEngine()

        struct Expectation {
            let file: String
            let encoding: ArchiveEncoding?
            let paths: [String]
        }

        let expectations: [Expectation] = [
            .init(file: "zip_filename_big5.zip", encoding: .big5, paths: [
                "臺灣大學招生簡章.txt",
                "繁體資料夾/會議記錄檔案.txt",
                "臺北市政府/環境保護局/資源回收公告.txt"
            ]),
            .init(file: "zip_filename_gb18030.zip", encoding: .gb18030, paths: [
                "犇羴鱻鑫淼焱垚资料.txt",
                "扩展汉字目录/㐀㐁㐂㐃测试文件.txt",
                "国家标准字符集/生僻字样本/㐄㐅㐆㐇编码报告.txt"
            ]),
            .init(file: "zip_filename_gbk.zip", encoding: .gb18030, paths: [
                "中国人民银行营业公告.txt",
                "中文资料夹/季度财务报告.txt",
                "北京市档案馆/朝阳区资料/建设项目审批通知书.txt"
            ]),
            .init(file: "zip_filename_shift_jis.zip", encoding: .shiftJIS, paths: [
                "日本語ファイル名テスト.txt",
                "東京都資料/会議議事録.txt",
                "大阪府立大学/工学研究科/入学試験問題集.txt"
            ]),
            .init(file: "zip_filename_euc_kr.zip", encoding: .eucKR, paths: [
                "한국어파일명이름테스트.txt",
                "서울특별시자료/행정민원공지사항.txt",
                "한국전자통신연구원/연구개발보고서/중간성과자료.txt"
            ]),
            .init(file: "zip_filename_cp437.zip", encoding: .cp437, paths: [
                "über-große-Straße.txt",
                "España-México/niño-año-canción.txt",
                "français-résumé/café-protégé/élève-déjà-vu.txt"
            ]),
            .init(file: "zip_filename_cp850.zip", encoding: .cp850, paths: [
                "Øresund-Portugal-Espanha-França-Ílhavo-Føroya.txt",
                "Sverige-Norge-Danmark/Øst-Øresund-Álbum-Âncora-Àrvore-ã.txt",
                "Österreich-Schweiz/België-Nederland/Øresund-Êxito-Ëvora-Èvora-Óbidos.txt"
            ]),
            .init(file: "zip_filename_cp1252.zip", encoding: .windows1252, paths: [
                "rapport-annuel-d’activité.txt",
                "café-naïve-résumé/élève-protégé.txt",
                "bilan-–-synthèse/Großbritannien-Straße/devis-€-final.txt"
            ]),
            .init(file: "zip_filename_utf8_noflag.zip", encoding: nil, paths: [
                "中文文件名编码检测.txt",
                "日本語資料/ファイル名テスト.txt",
                "한국어자료/اختبار-العربية/混合言語ファイル.txt"
            ]),
            .init(file: "zip_filename_utf8_baseline.zip", encoding: nil, paths: [
                "中文文件名编码检测.txt",
                "日本語資料/ファイル名テスト.txt",
                "한국어자료/اختبار-العربية/混合言語ファイル.txt"
            ])
        ]

        for exp in expectations {
            let url = try XCTUnwrap(Bundle.module.url(forResource: exp.file, withExtension: nil, subdirectory: "Fixtures"))
            let options = ArchiveOperationOptions(encoding: nil)
            let meta = try await engine.metadata(of: url, options: options)
            let entries = try await engine.listContents(of: url, options: options)
            let names = entries.map(\.path)

            XCTAssertEqual(meta.encoding, exp.encoding,
                "\(exp.file): expected encoding \(String(describing: exp.encoding)), got \(String(describing: meta.encoding))")
            XCTAssertEqual(names.count, exp.paths.count,
                "\(exp.file): expected \(exp.paths.count) paths, got \(names.count)")
            XCTAssertEqual(Set(names), Set(exp.paths),
                "\(exp.file): expected paths '\(exp.paths)', got '\(names)'")
        }
    }

    func testZIPRawDetectorFastPathUsesDetectedCharsetWithoutScoringRetries() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zip_filename_cp1252.zip", withExtension: nil, subdirectory: "Fixtures"))
        let recorder = CharsetRecorder()
        let engine = LibArchiveEngine(beforeReadEntryList: recorder.record)

        let metadata = try await engine.metadata(of: url, options: ArchiveOperationOptions(encoding: nil))

        XCTAssertEqual(metadata.encoding, .windows1252)
        XCTAssertEqual(recorder.values, [nil, "CP1252"])
    }

    func testZIPRawDetectorFastPathUsesCP850CharsetWithoutScoringRetries() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zip_filename_cp850.zip", withExtension: nil, subdirectory: "Fixtures"))
        let recorder = CharsetRecorder()
        let engine = LibArchiveEngine(beforeReadEntryList: recorder.record)

        let metadata = try await engine.metadata(of: url, options: ArchiveOperationOptions(encoding: nil))

        XCTAssertEqual(metadata.encoding, .cp850)
        XCTAssertEqual(recorder.values, [nil, "CP850"])
    }

    func testAutomaticEncodingPrioritySkipsExcludedCandidateCharsets() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zip_filename_cp1252.zip", withExtension: nil, subdirectory: "Fixtures"))
        let recorder = CharsetRecorder()
        let engine = LibArchiveEngine(beforeReadEntryList: recorder.record)

        _ = try await engine.metadata(
            of: url,
            options: ArchiveOperationOptions(encoding: nil, automaticEncodingPriority: [.cp850])
        )

        XCTAssertFalse(recorder.values.contains("CP1252"))
    }

    func testAutomaticEncodingPriorityControlsScoringFallbackOrder() async throws {
        let sourceURL = try XCTUnwrap(Bundle.module.url(forResource: "zip_filename_cp1252.zip", withExtension: nil, subdirectory: "Fixtures"))
        let archiveURL = try copyFixtureWithZIP64CentralDirectory(sourceURL)
        let recorder = CharsetRecorder()
        let engine = LibArchiveEngine(beforeReadEntryList: recorder.record)

        _ = try await engine.metadata(
            of: archiveURL,
            options: ArchiveOperationOptions(encoding: nil, automaticEncodingPriority: [.windows1252, .cp437])
        )

        XCTAssertEqual(recorder.values.prefix(3), [nil, "CP1252", "CP437"])
    }

    func testZIPUTF8NoFlagReturnsFirstReadWithoutLegacyRetries() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zip_filename_utf8_noflag.zip", withExtension: nil, subdirectory: "Fixtures"))
        let recorder = CharsetRecorder()
        let engine = LibArchiveEngine(beforeReadEntryList: recorder.record)

        let metadata = try await engine.metadata(of: url, options: ArchiveOperationOptions(encoding: nil))

        XCTAssertNil(metadata.encoding)
        XCTAssertEqual(recorder.values, [nil])
    }

    func testExplicitLegacyEncodingBypassesAutomaticDetection() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zip_filename_cp1252.zip", withExtension: nil, subdirectory: "Fixtures"))
        let recorder = CharsetRecorder()
        let engine = LibArchiveEngine(beforeReadEntryList: recorder.record)

        let entries = try await engine.listContents(of: url, options: ArchiveOperationOptions(encoding: .windows1252))

        XCTAssertEqual(entries.map(\.path), [
            "rapport-annuel-d’activité.txt",
            "café-naïve-résumé/élève-protégé.txt",
            "bilan-–-synthèse/Großbritannien-Straße/devis-€-final.txt"
        ])
        XCTAssertEqual(recorder.values, ["CP1252"])
    }

    func testZIPRawScannerFailureFallsBackToScoringPath() async throws {
        let sourceURL = try XCTUnwrap(Bundle.module.url(forResource: "zip_filename_cp1252.zip", withExtension: nil, subdirectory: "Fixtures"))
        let archiveURL = try copyFixtureWithZIP64CentralDirectory(sourceURL)
        let recorder = CharsetRecorder()
        let engine = LibArchiveEngine(beforeReadEntryList: recorder.record)

        XCTAssertThrowsError(try ZipRawNameScanner.rawNames(in: archiveURL)) { error in
            guard case ZipRawNameScanner.ScanError.scannerFailed(let message) = error else {
                return XCTFail("Expected scannerFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("ZIP64"), message)
        }

        let metadata = try await engine.metadata(of: archiveURL, options: ArchiveOperationOptions(encoding: nil))

        let calls = recorder.values
        XCTAssertEqual(metadata.encoding, .windows1252)
        XCTAssertFalse(calls.isEmpty)
        XCTAssertNil(calls[0])
        XCTAssertTrue(calls.contains("CP1252"))
        XCTAssertGreaterThan(calls.count, 2)
    }

    func testZIPRawScannerFailureCanFallbackToCP850ScoringPath() async throws {
        let sourceURL = try XCTUnwrap(Bundle.module.url(forResource: "zip_filename_cp850.zip", withExtension: nil, subdirectory: "Fixtures"))
        let archiveURL = try copyFixtureWithZIP64CentralDirectory(sourceURL)
        let recorder = CharsetRecorder()
        let engine = LibArchiveEngine(beforeReadEntryList: recorder.record)

        XCTAssertThrowsError(try ZipRawNameScanner.rawNames(in: archiveURL)) { error in
            guard case ZipRawNameScanner.ScanError.scannerFailed(let message) = error else {
                return XCTFail("Expected scannerFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("ZIP64"), message)
        }

        let entries = try await engine.listContents(of: archiveURL, options: ArchiveOperationOptions(encoding: nil))
        let calls = recorder.values

        XCTAssertEqual(entries.map(\.path), [
            "Øresund-Portugal-Espanha-França-Ílhavo-Føroya.txt",
            "Sverige-Norge-Danmark/Øst-Øresund-Álbum-Âncora-Àrvore-ã.txt",
            "Österreich-Schweiz/België-Nederland/Øresund-Êxito-Ëvora-Èvora-Óbidos.txt"
        ])
        XCTAssertFalse(calls.isEmpty)
        XCTAssertNil(calls[0])
        XCTAssertTrue(calls.contains("CP850"))
        XCTAssertGreaterThan(calls.count, 2)
    }

    func testLibarchiveCharsetMappings() async throws {
        XCTAssertNil(ArchiveEncoding.automatic.libarchiveCharset)
        XCTAssertNil(ArchiveEncoding.utf8.libarchiveCharset)
        XCTAssertEqual(ArchiveEncoding.gb18030.libarchiveCharset, "GB18030")
        XCTAssertEqual(ArchiveEncoding.big5.libarchiveCharset, "CP950")
        XCTAssertEqual(ArchiveEncoding.shiftJIS.libarchiveCharset, "CP932")
        XCTAssertEqual(ArchiveEncoding.eucKR.libarchiveCharset, "CP949")
        XCTAssertEqual(ArchiveEncoding.cp437.libarchiveCharset, "CP437")
        XCTAssertEqual(ArchiveEncoding.windows1252.libarchiveCharset, "CP1252")
        XCTAssertEqual(ArchiveEncoding.cp850.libarchiveCharset, "CP850")

        XCTAssertNil(ArchiveEncoding.automatic.libarchiveZipWriteCharset)
        XCTAssertEqual(ArchiveEncoding.utf8.libarchiveZipWriteCharset, "UTF-8")
        XCTAssertEqual(ArchiveEncoding.gb18030.libarchiveZipWriteCharset, "GB18030")
        XCTAssertEqual(ArchiveEncoding.big5.libarchiveZipWriteCharset, "CP950")
        XCTAssertEqual(ArchiveEncoding.shiftJIS.libarchiveZipWriteCharset, "CP932")
        XCTAssertEqual(ArchiveEncoding.eucKR.libarchiveZipWriteCharset, "CP949")
        XCTAssertEqual(ArchiveEncoding.cp437.libarchiveZipWriteCharset, "CP437")
        XCTAssertEqual(ArchiveEncoding.windows1252.libarchiveZipWriteCharset, "CP1252")
        XCTAssertEqual(ArchiveEncoding.cp850.libarchiveZipWriteCharset, "CP850")
    }


    func testCreateZipWithExplicitBig5FilenameEncodingRoundTrips() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("繁體檔案.txt")
        try Data("hello".utf8).write(to: source)
        let archive = directory.appendingPathComponent("big5-created.zip")
        let engine = LibArchiveEngine()
        let profile = CompressionProfile(
            name: "Big5 ZIP",
            format: .zip,
            level: .normal,
            filenameEncoding: .big5
        )

        _ = try await engine.createArchive(from: [source], to: archive, profile: profile)

        let entries = try await engine.listContents(of: archive)
        let metadata = try await engine.metadata(of: archive)

        XCTAssertEqual(entries.map(\.path), ["繁體檔案.txt"])
        XCTAssertEqual(metadata.encoding, .big5)
    }

    func testCreateZipWithExplicitUtf8FilenameEncodingRoundTrips() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("日本語-ファイル名.txt")
        try Data("hello".utf8).write(to: source)
        let archive = directory.appendingPathComponent("utf8-created.zip")
        let engine = LibArchiveEngine()
        let profile = CompressionProfile(
            name: "UTF8 ZIP",
            format: .zip,
            level: .normal,
            filenameEncoding: .utf8
        )

        _ = try await engine.createArchive(from: [source], to: archive, profile: profile)

        let entries = try await engine.listContents(of: archive)
        let metadata = try await engine.metadata(of: archive)

        XCTAssertEqual(entries.map(\.path), ["日本語-ファイル名.txt"])
        XCTAssertNil(metadata.encoding)
    }

    func testCreateZipFailsWhenFilenameCannotBeRepresentedInExplicitEncoding() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("表.txt")
        try Data("hello".utf8).write(to: source)
        let archive = directory.appendingPathComponent("cp437-fail.zip")
        let engine = LibArchiveEngine()
        let profile = CompressionProfile(
            name: "CP437 ZIP",
            format: .zip,
            level: .normal,
            filenameEncoding: .cp437
        )

        do {
            _ = try await engine.createArchive(from: [source], to: archive, profile: profile)
            XCTFail("Expected explicit-encoding failure")
        } catch LibArchiveError.writeFailed {
            XCTAssertFalse(fileManager.fileExists(atPath: archive.path), "Failed ZIP should be cleaned up")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateZipFailureDoesNotDeleteExistingArchive() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("表.txt")
        try Data("hello".utf8).write(to: source)
        let archive = directory.appendingPathComponent("existing.zip")
        let originalData = Data("keep me".utf8)
        try originalData.write(to: archive)
        let engine = LibArchiveEngine()
        let profile = CompressionProfile(
            name: "CP437 ZIP",
            format: .zip,
            level: .normal,
            filenameEncoding: .cp437
        )

        do {
            _ = try await engine.createArchive(from: [source], to: archive, profile: profile)
            XCTFail("Expected explicit-encoding failure")
        } catch LibArchiveError.writeFailed {
            XCTAssertEqual(try Data(contentsOf: archive), originalData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateZipFailureCleansUpTemporaryArchiveSibling() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("表.txt")
        try Data("hello".utf8).write(to: source)
        let archive = directory.appendingPathComponent("cleanup.zip")
        let engine = LibArchiveEngine()
        let profile = CompressionProfile(
            name: "CP437 ZIP",
            format: .zip,
            level: .normal,
            filenameEncoding: .cp437
        )

        do {
            _ = try await engine.createArchive(from: [source], to: archive, profile: profile)
            XCTFail("Expected explicit-encoding failure")
        } catch LibArchiveError.writeFailed {
            let leftovers = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".m7archiver-create-") }
            XCTAssertTrue(leftovers.isEmpty, "Temporary ZIP create files should be removed on failure")
            XCTAssertFalse(fileManager.fileExists(atPath: archive.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateZipFailsWhenSourceDisappearsAndPreservesExistingArchive() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("vanish.txt")
        try Data("hello".utf8).write(to: source)

        let archive = directory.appendingPathComponent("existing-missing-source.zip")
        let originalData = Data("keep me".utf8)
        try originalData.write(to: archive)

        let engine = LibArchiveEngine(beforeCreateArchive: {
            try? FileManager.default.removeItem(at: source)
        })

        do {
            _ = try await engine.createArchive(from: [source], to: archive, profile: BuiltInCompressionProfiles.fastZIP)
            XCTFail("Expected missing source failure")
        } catch LibArchiveError.writeFailed {
            XCTAssertEqual(try Data(contentsOf: archive), originalData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateZipFailsWhenSourceBecomesUnreadableAndPreservesExistingArchive() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("locked.txt")
        try Data("hello".utf8).write(to: source)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path) }

        let archive = directory.appendingPathComponent("existing.zip")
        let originalData = Data("keep me".utf8)
        try originalData.write(to: archive)

        let engine = LibArchiveEngine()

        do {
            _ = try await engine.createArchive(from: [source], to: archive, profile: BuiltInCompressionProfiles.fastZIP)
            XCTFail("Expected unreadable source failure")
        } catch LibArchiveError.writeFailed {
            XCTAssertEqual(try Data(contentsOf: archive), originalData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateZipNormalizesDecomposedFilenamesForExplicitLegacyEncoding() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let decomposed = "cafe\u{301}.txt"
        let source = directory.appendingPathComponent(decomposed)
        try Data("hello".utf8).write(to: source)
        let archive = directory.appendingPathComponent("cp1252-normalized.zip")
        let engine = LibArchiveEngine()
        let profile = CompressionProfile(
            name: "Windows 1252 ZIP",
            format: .zip,
            level: .normal,
            filenameEncoding: .windows1252
        )

        _ = try await engine.createArchive(from: [source], to: archive, profile: profile)

        let options = ArchiveOperationOptions(encoding: .windows1252)
        let entries = try await engine.listContents(of: archive, options: options)
        XCTAssertEqual(entries.map(\.path), ["café.txt"])
    }

    func testCreateListMetadataAndTestZipArchive() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: source)
        let archive = directory.appendingPathComponent("fixture.zip")
        let engine = LibArchiveEngine()

        _ = try await engine.createArchive(from: [source], to: archive, profile: BuiltInCompressionProfiles.fastZIP)
        let entries = try await engine.listContents(of: archive)
        let metadata = try await engine.metadata(of: archive)
        let result = try await engine.testArchive(archive)

        XCTAssertEqual(entries.map(\ .path), ["hello.txt"])
        XCTAssertEqual(metadata.format, .zip)
        XCTAssertEqual(metadata.entriesCount, 1)
        XCTAssertEqual(result.entries.count, 1)
    }

    func testExtractZipMaterializesEntriesUnderDestination() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: source)
        let archive = directory.appendingPathComponent("fixture.zip")
        let engine = LibArchiveEngine()

        _ = try await engine.createArchive(from: [source], to: archive, profile: BuiltInCompressionProfiles.fastZIP)

        let destination = directory.appendingPathComponent("out", isDirectory: true)
        _ = try await engine.extract(archive, to: destination)

        let extracted = try Data(contentsOf: destination.appendingPathComponent("hello.txt"))
        XCTAssertEqual(String(data: extracted, encoding: .utf8), "hello")
    }

    func testExtractMergesExistingDirectoriesWithoutDeletingContents() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let sourceRoot = directory.appendingPathComponent("source", isDirectory: true)
        let folder = sourceRoot.appendingPathComponent("folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: folder.appendingPathComponent("new.txt"))
        let archive = directory.appendingPathComponent("fixture.zip")
        let engine = LibArchiveEngine()
        _ = try await engine.createArchive(from: [folder.appendingPathComponent("new.txt")], to: archive, profile: BuiltInCompressionProfiles.fastZIP)

        let destination = directory.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("keep.txt"))

        _ = try await engine.extract(archive, to: destination)

        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("keep.txt")), encoding: .utf8), "keep")
        XCTAssertEqual(String(data: try Data(contentsOf: destination.appendingPathComponent("new.txt")), encoding: .utf8), "new")
    }

    func testExtractionRejectsSymlinkDestinationComponents() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: source)
        let archive = directory.appendingPathComponent("fixture.zip")
        let engine = LibArchiveEngine()
        _ = try await engine.createArchive(from: [source], to: archive, profile: BuiltInCompressionProfiles.fastZIP)

        let destination = directory.appendingPathComponent("out", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: destination.appendingPathComponent("payload.txt"),
            withDestinationURL: outside.appendingPathComponent("payload.txt")
        )

        do {
            _ = try await engine.extract(archive, to: destination)
            XCTFail("Expected symlink destination rejection")
        } catch ArchiveExtractionFinalizationError.unsafeDestinationPath("payload.txt") {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateZipFromDirectoryPreservesRelativeFilePaths() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nested.appendingPathComponent("file.txt"))
        let empty = folder.appendingPathComponent("empty", isDirectory: true)
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)
        let macosx = folder.appendingPathComponent("__MACOSX", isDirectory: true)
        try fileManager.createDirectory(at: macosx, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: macosx.appendingPathComponent("resource-fork"))
        try Data("junk".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        let archive = directory.appendingPathComponent("folder.zip")
        let engine = LibArchiveEngine()

        _ = try await engine.createArchive(from: [folder], to: archive, profile: BuiltInCompressionProfiles.fastZIP)

        let entries = try await engine.listContents(of: archive)
        XCTAssertEqual(Set(entries.map(\.path)), Set(["folder/", "folder/nested/", "folder/nested/file.txt", "folder/empty/"]))
    }

    func testCreateZipFromEmptyDirectoryPreservesRootDirectory() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let folder = directory.appendingPathComponent("empty-root", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("empty-root.zip")
        let engine = LibArchiveEngine()

        _ = try await engine.createArchive(from: [folder], to: archive, profile: BuiltInCompressionProfiles.fastZIP)

        let entries = try await engine.listContents(of: archive)
        XCTAssertEqual(entries.map(\.path), ["empty-root/"])
    }

    func testCreateZipIgnoresTopLevelDirectoryRuleWithoutTrailingSlash() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let macosx = directory.appendingPathComponent("__MACOSX", isDirectory: true)
        try fileManager.createDirectory(at: macosx, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: macosx.appendingPathComponent("resource-fork"))
        let archive = directory.appendingPathComponent("ignored.zip")
        let engine = LibArchiveEngine()

        do {
            _ = try await engine.createArchive(from: [URL(fileURLWithPath: macosx.path)], to: archive, profile: BuiltInCompressionProfiles.fastZIP)
            XCTFail("Expected missingSources")
        } catch LibArchiveError.missingSources {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateZipFailsWhenIgnoreRulesRemoveEverySource() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent(".DS_Store")
        try Data("junk".utf8).write(to: source)
        let engine = LibArchiveEngine()

        do {
            _ = try await engine.createArchive(
                from: [source],
                to: directory.appendingPathComponent("empty.zip"),
                profile: BuiltInCompressionProfiles.fastZIP
            )
            XCTFail("Expected missingSources")
        } catch LibArchiveError.missingSources {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateZipStoreAndDeflateHonorCompressionLevel() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("compressible.txt")
        let payload = String(repeating: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", count: 8_192)
        try Data(payload.utf8).write(to: source)

        let storeArchive = directory.appendingPathComponent("stored.zip")
        let deflateArchive = directory.appendingPathComponent("deflated.zip")
        let engine = LibArchiveEngine()

        _ = try await engine.createArchive(
            from: [source],
            to: storeArchive,
            profile: CompressionProfile(name: "Stored ZIP", format: .zip, level: .store)
        )
        _ = try await engine.createArchive(
            from: [source],
            to: deflateArchive,
            profile: CompressionProfile(name: "Deflated ZIP", format: .zip, level: .normal)
        )

        let storeAttributes = try fileManager.attributesOfItem(atPath: storeArchive.path)
        let deflateAttributes = try fileManager.attributesOfItem(atPath: deflateArchive.path)
        let storeSize = try XCTUnwrap(storeAttributes[.size] as? NSNumber).int64Value
        let deflateSize = try XCTUnwrap(deflateAttributes[.size] as? NSNumber).int64Value

        XCTAssertGreaterThan(storeSize, deflateSize, "Stored ZIP should be larger than deflated ZIP for compressible data")
        XCTAssertLessThan(deflateSize * 4, storeSize, "Deflated ZIP should be meaningfully smaller than stored ZIP")

        let storedExtractDestination = directory.appendingPathComponent("stored-out", isDirectory: true)
        let deflatedExtractDestination = directory.appendingPathComponent("deflated-out", isDirectory: true)
        _ = try await engine.extract(storeArchive, to: storedExtractDestination)
        _ = try await engine.extract(deflateArchive, to: deflatedExtractDestination)

        XCTAssertEqual(
            try String(contentsOf: storedExtractDestination.appendingPathComponent("compressible.txt"), encoding: .utf8),
            payload
        )
        XCTAssertEqual(
            try String(contentsOf: deflatedExtractDestination.appendingPathComponent("compressible.txt"), encoding: .utf8),
            payload
        )
    }

    func testCreateEncryptedZipRoundTripsWithPassword() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("secret.txt")
        let payload = "top secret payload"
        try Data(payload.utf8).write(to: source)
        let archive = directory.appendingPathComponent("fixture-encrypted.zip")
        let engine = LibArchiveEngine()
        let password = "hunter2"

        _ = try await engine.createArchive(
            from: [source],
            to: archive,
            profile: BuiltInCompressionProfiles.fastZIP,
            password: password
        )

        let entries = try await engine.listContents(of: archive)
        XCTAssertEqual(entries.map(\.path), ["secret.txt"])
        XCTAssertTrue(entries.allSatisfy(\.isEncrypted))

        let plainDestination = directory.appendingPathComponent("plain", isDirectory: true)
        var extractWithoutPasswordFailed = false
        do {
            _ = try await engine.extract(archive, to: plainDestination)
        } catch {
            extractWithoutPasswordFailed = true
        }
        XCTAssertTrue(extractWithoutPasswordFailed, "extract should fail without the password")

        let okDestination = directory.appendingPathComponent("ok", isDirectory: true)
        let options = ArchiveOperationOptions(
            passwordProvider: { _ in password }
        )
        _ = try await engine.extract(archive, to: okDestination, options: options)

        let extracted = try Data(contentsOf: okDestination.appendingPathComponent("secret.txt"))
        XCTAssertEqual(String(data: extracted, encoding: .utf8), payload)
    }

    private func copyFixtureWithZIP64CentralDirectory(_ sourceURL: URL) throws -> URL {
        var original = try Data(contentsOf: sourceURL)
        let eocdSignature = Data([0x50, 0x4B, 0x05, 0x06])
        let eocdOffset = try XCTUnwrap(original.lastRange(of: eocdSignature)?.lowerBound)
        let commentLength = Int(original.littleEndianUInt16(at: eocdOffset + 20))
        let commentStart = eocdOffset + 22
        let commentEnd = commentStart + commentLength
        guard commentEnd <= original.count else { throw ZIP64FixtureError.invalidEOCDComment }

        let entriesOnDisk = original.littleEndianUInt16(at: eocdOffset + 8)
        let totalEntries = original.littleEndianUInt16(at: eocdOffset + 10)
        let centralDirectorySize = original.littleEndianUInt32(at: eocdOffset + 12)
        let centralDirectoryOffset = original.littleEndianUInt32(at: eocdOffset + 16)
        let comment = original[commentStart..<commentEnd]

        original.removeSubrange(eocdOffset..<commentEnd)
        let zip64EOCDOffset = UInt64(original.count)

        var zip64EOCD = Data()
        zip64EOCD.appendLittleEndianUInt32(0x06064B50)
        zip64EOCD.appendLittleEndianUInt64(44)
        zip64EOCD.appendLittleEndianUInt16(45)
        zip64EOCD.appendLittleEndianUInt16(45)
        zip64EOCD.appendLittleEndianUInt32(0)
        zip64EOCD.appendLittleEndianUInt32(0)
        zip64EOCD.appendLittleEndianUInt64(UInt64(entriesOnDisk))
        zip64EOCD.appendLittleEndianUInt64(UInt64(totalEntries))
        zip64EOCD.appendLittleEndianUInt64(UInt64(centralDirectorySize))
        zip64EOCD.appendLittleEndianUInt64(UInt64(centralDirectoryOffset))

        var locator = Data()
        locator.appendLittleEndianUInt32(0x07064B50)
        locator.appendLittleEndianUInt32(0)
        locator.appendLittleEndianUInt64(zip64EOCDOffset)
        locator.appendLittleEndianUInt32(1)

        var eocd = Data()
        eocd.appendLittleEndianUInt32(0x06054B50)
        eocd.appendLittleEndianUInt16(0)
        eocd.appendLittleEndianUInt16(0)
        eocd.appendLittleEndianUInt16(0xFFFF)
        eocd.appendLittleEndianUInt16(0xFFFF)
        eocd.appendLittleEndianUInt32(0xFFFF_FFFF)
        eocd.appendLittleEndianUInt32(0xFFFF_FFFF)
        eocd.appendLittleEndianUInt16(UInt16(comment.count))
        eocd.append(comment)

        original.append(zip64EOCD)
        original.append(locator)
        original.append(eocd)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        try original.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class CharsetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String?] = []

    var values: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func record(_ charset: String?) {
        lock.lock()
        storedValues.append(charset)
        lock.unlock()
    }
}

private enum ZIP64FixtureError: Error {
    case invalidEOCDComment
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendLittleEndianUInt64(_ value: UInt64) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 56) & 0xFF))
    }
}
