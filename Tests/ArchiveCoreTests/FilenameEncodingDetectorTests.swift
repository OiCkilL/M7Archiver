import Foundation
import XCTest
@testable import ArchiveCore

final class FilenameEncodingDetectorTests: XCTestCase {
    func testDetectsRepositoryLegacyFixtureSamples() throws {
        let expectations: [String: ArchiveEncoding] = [
            "zip_filename_big5.zip": .big5,
            "zip_filename_euc_kr.zip": .eucKR,
            "zip_filename_gb18030.zip": .gb18030,
            "zip_filename_gbk.zip": .gb18030,
            "zip_filename_shift_jis.zip": .shiftJIS,
            "zip_filename_cp437.zip": .cp437,
            "zip_filename_cp850.zip": .cp850,
            "zip_filename_cp1252.zip": .windows1252
        ]
        let detector = FilenameEncodingDetector()
        let rows = try loadManifestRows()

        for artifact in expectations.keys.sorted() {
            let sample = try XCTUnwrap(legacyDetectionSample(for: artifact, rows: rows), artifact)
            let result = try XCTUnwrap(detector.detect(sample), artifact)
            let expectedPaths = rows
                .filter { $0.artifact == artifact }
                .sorted { $0.entryIndex < $1.entryIndex }
                .map(\.expectedPath)
                .joined(separator: "\n")

            XCTAssertEqual(result.encoding, expectations[artifact], artifact)
            XCTAssertEqual(result.convertedString, expectedPaths, artifact)
        }
    }

    func testLatinTiebreakerPrefersCP850SpecificBytes() throws {
        let cp437 = try defaultCandidate(.cp437)
        let windows1252 = try defaultCandidate(.windows1252)
        let cp850 = try defaultCandidate(.cp850)
        let sample = Data([0x9D, 0x87, 0xD6, 0x9B, 0x9D, 0xB5, 0xC6, 0xD2])

        for candidates in [[cp437, windows1252, cp850], [cp850, windows1252, cp437]] {
            let result = try XCTUnwrap(FilenameEncodingDetector(candidates: candidates).detect(sample))
            XCTAssertEqual(result.encoding, .cp850)
            XCTAssertEqual(result.convertedString, "ØçÍøØÁãÊ")
        }
    }

    func testLatinTiebreakerPrefersWindows1252SpecificBytes() throws {
        let cp437 = try defaultCandidate(.cp437)
        let windows1252 = try defaultCandidate(.windows1252)
        let sample = Data([0x80, 0x92, 0x96, 0x99, 0x89, 0x9B, 0x97, 0x93])

        for candidates in [[cp437, windows1252], [windows1252, cp437]] {
            let result = try XCTUnwrap(FilenameEncodingDetector(candidates: candidates).detect(sample))
            XCTAssertEqual(result.encoding, .windows1252)
            XCTAssertEqual(result.convertedString, "€’–™‰›—“")
        }
    }

    func testLatinTiebreakerDoesNotTreatWindows1252BytesAsCP850Signal() throws {
        let cp437 = try defaultCandidate(.cp437)
        let windows1252 = try defaultCandidate(.windows1252)
        let cp850 = try defaultCandidate(.cp850)
        let sample = Data([0xD6, 0x9B, 0xC9, 0xE0, 0xE7, 0xE9, 0xF6, 0xFC, 0xDF])

        let result = try XCTUnwrap(FilenameEncodingDetector(candidates: [cp437, windows1252, cp850]).detect(sample))
        XCTAssertEqual(result.encoding, .windows1252)
        XCTAssertEqual(result.convertedString, "Ö›Éàçéöüß")
    }

    func testLatinTiebreakerPrefersCP437SpecificBytes() throws {
        let cp437 = try defaultCandidate(.cp437)
        let windows1252 = try defaultCandidate(.windows1252)
        let sample = Data([0x81, 0x82, 0x87, 0x8A, 0xA1, 0xA2, 0xA4, 0xE1])

        for candidates in [[cp437, windows1252], [windows1252, cp437]] {
            let result = try XCTUnwrap(FilenameEncodingDetector(candidates: candidates).detect(sample))
            XCTAssertEqual(result.encoding, .cp437)
            XCTAssertEqual(result.convertedString, "üéçèíóñß")
        }
    }

    func testLatinTiebreakerRejectsShortAmbiguousSamples() throws {
        let cp437 = try defaultCandidate(.cp437)
        let windows1252 = try defaultCandidate(.windows1252)
        let sample = Data([0x96])

        XCTAssertNil(FilenameEncodingDetector(candidates: [cp437, windows1252]).detectEncoding(sample))
        XCTAssertNil(FilenameEncodingDetector(candidates: [windows1252, cp437]).detectEncoding(sample))
    }

    func testReturnsNilForValidUTF8Samples() throws {
        let detector = FilenameEncodingDetector()
        let rows = try loadManifestRows()
        let utf8NoFlag = rows
            .filter { $0.artifact == "zip_filename_utf8_noflag.zip" }
            .map(\.rawNameBytes)

        XCTAssertEqual(utf8NoFlag.count, 3)
        for bytes in utf8NoFlag {
            XCTAssertNil(detector.detectEncoding(bytes))
        }
        XCTAssertNil(ZipRawNameScanner.legacyDetectionSample(from: utf8NoFlag.map {
            ZipRawNameScanner.RawName(bytes: $0, flags: 0, unicodePathBytes: nil)
        }))
    }

    func testReturnsNilForUndecodableCandidateBytes() throws {
        let detector = FilenameEncodingDetector(candidates: [
            FilenameEncodingDetector.Candidate(archiveEncoding: .shiftJIS, foundationEncoding: .shiftJIS)
        ])

        XCTAssertNil(detector.detectEncoding(Data([0x80])))
    }

    func testUsesCandidatePriorityAfterSkippingInvalidFoundationResult() throws {
        let rows = try loadManifestRows()
        let sample = try XCTUnwrap(legacyDetectionSample(for: "zip_filename_cp850.zip", rows: rows))
        let gb18030 = try XCTUnwrap(FilenameEncodingDetector.defaultCandidates.first { $0.archiveEncoding == .gb18030 })
        let cp850 = try XCTUnwrap(FilenameEncodingDetector.defaultCandidates.first { $0.archiveEncoding == .cp850 })

        XCTAssertNil(FilenameEncodingDetector(candidates: [gb18030]).detectEncoding(sample))
        XCTAssertEqual(FilenameEncodingDetector(candidates: [gb18030, cp850]).detectEncoding(sample), .cp850)
    }

    private func defaultCandidate(_ encoding: ArchiveEncoding) throws -> FilenameEncodingDetector.Candidate {
        try XCTUnwrap(FilenameEncodingDetector.defaultCandidates.first { $0.archiveEncoding == encoding })
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

    private func legacyDetectionSample(for artifact: String, rows: [ManifestRow]) throws -> Data? {
        let rawNames = rows
            .filter { $0.artifact == artifact }
            .sorted { $0.entryIndex < $1.entryIndex }
            .map {
                ZipRawNameScanner.RawName(
                    bytes: $0.rawNameBytes,
                    flags: $0.utf8Flag == "yes" ? ZipRawNameScanner.utf8Flag : 0,
                    unicodePathBytes: nil
                )
            }
        return ZipRawNameScanner.legacyDetectionSample(from: rawNames)
    }
}

private struct ManifestRow {
    let artifact: String
    let entryIndex: Int
    let utf8Flag: String
    let expectedPath: String
    let rawNameBytes: Data

    init(line: String) throws {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard columns.count == 10 else { throw ManifestError.invalidColumnCount }
        guard let entryIndex = Int(columns[1]) else { throw ManifestError.invalidEntryIndex }
        self.artifact = columns[0]
        self.entryIndex = entryIndex
        self.utf8Flag = columns[4]
        self.expectedPath = columns[7]
        self.rawNameBytes = try Data(hex: columns[8])
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
}

private enum HexError: Error {
    case invalidLength
    case invalidByte
}
