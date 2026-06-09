import Foundation
import XCTest
@testable import ArchiveCore

final class ZipRawNameScannerTests: XCTestCase {
    func testScannerMatchesFixtureManifestRawNameHexAndFlags() throws {
        let rows = try loadManifestRows()
        let grouped = Dictionary(grouping: rows, by: \.artifact)

        for artifact in grouped.keys.sorted() {
            let archiveURL = try XCTUnwrap(fixtureURL(artifact))
            let expectedRows = try XCTUnwrap(grouped[artifact]?.sorted { $0.entryIndex < $1.entryIndex })
            let rawNames = try ZipRawNameScanner.rawNames(in: archiveURL)

            XCTAssertEqual(rawNames.count, expectedRows.count, artifact)
            for (rawName, row) in zip(rawNames, expectedRows) {
                XCTAssertEqual(rawName.bytes, try Data(hex: row.rawNameHex), "\(artifact) entry \(row.entryIndex)")
                XCTAssertEqual(rawName.hasUTF8Flag, row.utf8Flag == "yes", "\(artifact) entry \(row.entryIndex)")
                XCTAssertNil(rawName.unicodePathBytes, "\(artifact) entry \(row.entryIndex) should not have a Unicode path extra")
            }
        }
    }

    func testScannerSupportsEOCDComment() throws {
        let archiveURL = try XCTUnwrap(fixtureURL("zip_filename_shift_jis.zip"))
        let commented = try copyFixtureWithEOCDComment(archiveURL, comment: Data("comment".utf8))

        let expected = try ZipRawNameScanner.rawNames(in: archiveURL).map(\.bytes)
        let actual = try ZipRawNameScanner.rawNames(in: commented).map(\.bytes)

        XCTAssertEqual(actual, expected)
    }

    func testScannerSupportsSFXPrefix() throws {
        let archiveURL = try XCTUnwrap(fixtureURL("zip_filename_big5.zip"))
        let sfxArchive = try copyFixtureWithSFXPrefix(archiveURL, prefix: Data("#!/bin/sh\nexit 0\n".utf8))

        let expected = try ZipRawNameScanner.rawNames(in: archiveURL).map(\.bytes)
        let actual = try ZipRawNameScanner.rawNames(in: sfxArchive).map(\.bytes)

        XCTAssertEqual(actual, expected)
    }

    func testScannerPreservesStoredPathSeparators() throws {
        let archiveURL = try XCTUnwrap(fixtureURL("zip_filename_gbk.zip"))
        let rawNames = try ZipRawNameScanner.rawNames(in: archiveURL)
        let slashByte = UInt8(ascii: "/")

        XCTAssertFalse(rawNames[0].bytes.contains(slashByte))
        XCTAssertEqual(rawNames[1].bytes.filter { $0 == slashByte }.count, 1)
        XCTAssertEqual(rawNames[2].bytes.filter { $0 == slashByte }.count, 2)
    }

    func testScannerParsesValidUnicodePathExtraField() throws {
        let rawName = Data([0x66, 0x82, 0x2e, 0x74, 0x78, 0x74]) // café.txt in CP437
        let unicodePath = Data("café.txt".utf8)
        let archive = try makeArchiveWithUnicodePathExtra(rawName: rawName, unicodePath: unicodePath)

        let rawNames = try ZipRawNameScanner.rawNames(in: archive)

        XCTAssertEqual(rawNames.count, 1)
        XCTAssertEqual(rawNames[0].bytes, rawName)
        XCTAssertEqual(rawNames[0].unicodePathBytes, unicodePath)
        XCTAssertNil(ZipRawNameScanner.legacyDetectionSample(from: rawNames))
    }

    func testScannerRejectsOverlongUnicodePathExtraPayload() throws {
        let rawName = Data([0x66, 0x82, 0x2e, 0x74, 0x78, 0x74]) // café.txt in CP437
        let overlongUTF8 = Data([0xC1, 0x81])
        let archive = try makeArchiveWithUnicodePathExtra(rawName: rawName, unicodePath: overlongUTF8)

        let rawNames = try ZipRawNameScanner.rawNames(in: archive)

        XCTAssertEqual(rawNames.count, 1)
        XCTAssertEqual(rawNames[0].bytes, rawName)
        XCTAssertNil(rawNames[0].unicodePathBytes)
        XCTAssertEqual(ZipRawNameScanner.legacyDetectionSample(from: rawNames), rawName)
    }

    func testLegacyDetectionSampleSkipsUTF8FlagUnicodePathAndValidUTF8Entries() throws {
        let cp437 = ZipRawNameScanner.RawName(bytes: Data([0x81, 0x2e, 0x74, 0x78, 0x74]), flags: 0, unicodePathBytes: nil)
        let utf8Flagged = ZipRawNameScanner.RawName(bytes: Data([0xE6, 0xB5, 0x8B]), flags: ZipRawNameScanner.utf8Flag, unicodePathBytes: nil)
        let unicodePath = ZipRawNameScanner.RawName(bytes: Data([0x82, 0x2e, 0x74, 0x78, 0x74]), flags: 0, unicodePathBytes: Data("é.txt".utf8))
        let utf8NoFlag = ZipRawNameScanner.RawName(bytes: Data("中文.txt".utf8), flags: 0, unicodePathBytes: nil)
        let anotherLegacy = ZipRawNameScanner.RawName(bytes: Data([0x84, 0x2e, 0x74, 0x78, 0x74]), flags: 0, unicodePathBytes: nil)

        let sample = try XCTUnwrap(ZipRawNameScanner.legacyDetectionSample(from: [cp437, utf8Flagged, unicodePath, utf8NoFlag, anotherLegacy]))

        XCTAssertEqual(sample, Data([0x81, 0x2e, 0x74, 0x78, 0x74, 0x0A, 0x84, 0x2e, 0x74, 0x78, 0x74]))
    }

    func testLegacyDetectionSampleSkipsUTF8NoFlagFixture() throws {
        let archiveURL = try XCTUnwrap(fixtureURL("zip_filename_utf8_noflag.zip"))
        let rawNames = try ZipRawNameScanner.rawNames(in: archiveURL)

        XCTAssertNil(ZipRawNameScanner.legacyDetectionSample(from: rawNames))
    }

    func testScannerFailuresAreNonFatalThroughOptionalWrapper() throws {
        let archiveURL = try XCTUnwrap(fixtureURL("zip_filename_utf8_baseline.zip"))
        var bytes = try Data(contentsOf: archiveURL)
        bytes.removeLast(12)
        let malformed = try writeTemporaryArchive(bytes)

        XCTAssertThrowsError(try ZipRawNameScanner.rawNames(in: malformed))
        XCTAssertNil(ZipRawNameScanner.rawNamesIfAvailable(in: malformed))
    }

    private func fixtureURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    }

    private func loadManifestRows() throws -> [ManifestRow] {
        let url = try XCTUnwrap(fixtureURL("filename_encoding_manifest.tsv"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return try lines.dropFirst().map(ManifestRow.init(line:))
    }

    private func copyFixtureWithEOCDComment(_ sourceURL: URL, comment: Data) throws -> URL {
        var bytes = try Data(contentsOf: sourceURL)
        let eocdOffset = try XCTUnwrap(bytes.lastRange(of: Data([0x50, 0x4B, 0x05, 0x06]))?.lowerBound)
        bytes.replaceLittleEndianUInt16(at: eocdOffset + 20, with: UInt16(comment.count))
        bytes.append(comment)
        return try writeTemporaryArchive(bytes)
    }

    private func copyFixtureWithSFXPrefix(_ sourceURL: URL, prefix: Data) throws -> URL {
        let original = try Data(contentsOf: sourceURL)
        let eocdOffset = try XCTUnwrap(original.lastRange(of: Data([0x50, 0x4B, 0x05, 0x06]))?.lowerBound)
        let centralDirectoryOffset = original.littleEndianUInt32(at: eocdOffset + 16)

        var bytes = Data()
        bytes.append(prefix)
        bytes.append(original)
        bytes.replaceLittleEndianUInt32(at: prefix.count + eocdOffset + 16, with: centralDirectoryOffset + UInt32(prefix.count))
        return try writeTemporaryArchive(bytes)
    }

    private func makeArchiveWithUnicodePathExtra(rawName: Data, unicodePath: Data) throws -> URL {
        var extra = Data()
        var payload = Data()
        payload.append(1)
        payload.appendLittleEndianUInt32(crc32(rawName))
        payload.append(unicodePath)
        extra.appendLittleEndianUInt16(0x7075)
        extra.appendLittleEndianUInt16(UInt16(payload.count))
        extra.append(payload)

        let content = Data("payload".utf8)
        let crc = crc32(content)

        var local = Data()
        local.appendLittleEndianUInt32(0x04034B50)
        local.appendLittleEndianUInt16(20)
        local.appendLittleEndianUInt16(0)
        local.appendLittleEndianUInt16(0)
        local.appendLittleEndianUInt16(0)
        local.appendLittleEndianUInt16((1 << 5) | 1)
        local.appendLittleEndianUInt32(crc)
        local.appendLittleEndianUInt32(UInt32(content.count))
        local.appendLittleEndianUInt32(UInt32(content.count))
        local.appendLittleEndianUInt16(UInt16(rawName.count))
        local.appendLittleEndianUInt16(0)
        local.append(rawName)
        local.append(content)

        var central = Data()
        central.appendLittleEndianUInt32(0x02014B50)
        central.appendLittleEndianUInt16((3 << 8) | 20)
        central.appendLittleEndianUInt16(20)
        central.appendLittleEndianUInt16(0)
        central.appendLittleEndianUInt16(0)
        central.appendLittleEndianUInt16(0)
        central.appendLittleEndianUInt16((1 << 5) | 1)
        central.appendLittleEndianUInt32(crc)
        central.appendLittleEndianUInt32(UInt32(content.count))
        central.appendLittleEndianUInt32(UInt32(content.count))
        central.appendLittleEndianUInt16(UInt16(rawName.count))
        central.appendLittleEndianUInt16(UInt16(extra.count))
        central.appendLittleEndianUInt16(0)
        central.appendLittleEndianUInt16(0)
        central.appendLittleEndianUInt16(0)
        central.appendLittleEndianUInt32(0o100644 << 16)
        central.appendLittleEndianUInt32(0)
        central.append(rawName)
        central.append(extra)

        let centralOffset = UInt32(local.count)
        let centralSize = UInt32(central.count)

        var eocd = Data()
        eocd.appendLittleEndianUInt32(0x06054B50)
        eocd.appendLittleEndianUInt16(0)
        eocd.appendLittleEndianUInt16(0)
        eocd.appendLittleEndianUInt16(1)
        eocd.appendLittleEndianUInt16(1)
        eocd.appendLittleEndianUInt32(centralSize)
        eocd.appendLittleEndianUInt32(centralOffset)
        eocd.appendLittleEndianUInt16(0)

        var archive = Data()
        archive.append(local)
        archive.append(central)
        archive.append(eocd)
        return try writeTemporaryArchive(archive)
    }

    private func writeTemporaryArchive(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private struct ManifestRow {
    let artifact: String
    let entryIndex: Int
    let utf8Flag: String
    let rawNameHex: String

    init(line: String) throws {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard columns.count == 10 else { throw ManifestError.invalidColumnCount }
        guard let entryIndex = Int(columns[1]) else { throw ManifestError.invalidEntryIndex }
        self.artifact = columns[0]
        self.entryIndex = entryIndex
        self.utf8Flag = columns[4]
        self.rawNameHex = columns[8]
    }
}

private enum ManifestError: Error {
    case invalidColumnCount
    case invalidEntryIndex
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw HexError.invalidLength }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw HexError.invalidByte }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    mutating func replaceLittleEndianUInt16(at offset: Int, with value: UInt16) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func replaceLittleEndianUInt32(at offset: Int, with value: UInt32) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
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
}

private enum HexError: Error {
    case invalidLength
    case invalidByte
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
    }
    return crc ^ 0xFFFF_FFFF
}
