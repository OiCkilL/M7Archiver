import XCTest

final class FilenameEncodingFixtureTests: XCTestCase {
    func testFilenameEncodingFixturesAreRepositoryOwnedAndEntryLevel() throws {
        let rows = try loadManifestRows()
        let grouped = Dictionary(grouping: rows, by: \.artifact)
        let expectedArtifacts: [String: ArtifactExpectation] = [
            "zip_filename_gbk.zip": .init(filenameEncoding: "gbk", expectedArchiveEncoding: "gb18030", utf8Flag: "no"),
            "zip_filename_gb18030.zip": .init(filenameEncoding: "gb18030", expectedArchiveEncoding: "gb18030", utf8Flag: "no"),
            "zip_filename_big5.zip": .init(filenameEncoding: "big5", expectedArchiveEncoding: "big5", utf8Flag: "no"),
            "zip_filename_shift_jis.zip": .init(filenameEncoding: "shift_jis", expectedArchiveEncoding: "shiftJIS", utf8Flag: "no"),
            "zip_filename_euc_kr.zip": .init(filenameEncoding: "euc_kr", expectedArchiveEncoding: "eucKR", utf8Flag: "no"),
            "zip_filename_cp437.zip": .init(filenameEncoding: "cp437", expectedArchiveEncoding: "cp437", utf8Flag: "no"),
            "zip_filename_cp850.zip": .init(filenameEncoding: "cp850", expectedArchiveEncoding: "cp850", utf8Flag: "no"),
            "zip_filename_cp1252.zip": .init(filenameEncoding: "cp1252", expectedArchiveEncoding: "windows1252", utf8Flag: "no"),
            "zip_filename_utf8_noflag.zip": .init(filenameEncoding: "utf-8", expectedArchiveEncoding: "none", utf8Flag: "no"),
            "zip_filename_utf8_baseline.zip": .init(filenameEncoding: "utf-8", expectedArchiveEncoding: "none", utf8Flag: "yes")
        ]

        XCTAssertEqual(Set(grouped.keys), Set(expectedArtifacts.keys))

        for artifact in expectedArtifacts.keys.sorted() {
            let expectation = try XCTUnwrap(expectedArtifacts[artifact])
            XCTAssertNotNil(fixtureURL(artifact), "Missing fixture archive: \(artifact)")
            let artifactRows = try XCTUnwrap(grouped[artifact]?.sorted { $0.entryIndex < $1.entryIndex })
            XCTAssertEqual(artifactRows.map(\.entryIndex), [0, 1, 2], "\(artifact) should use entry-level manifest rows")
            XCTAssertEqual(artifactRows.map { $0.expectedPath.filter { $0 == "/" }.count }, [0, 1, 2], "\(artifact) should cover top-level, one-level nested, and two-level nested paths")

            for row in artifactRows {
                XCTAssertEqual(row.filenameEncoding, expectation.filenameEncoding)
                XCTAssertEqual(row.expectedArchiveEncoding, expectation.expectedArchiveEncoding)
                XCTAssertEqual(row.utf8Flag, expectation.utf8Flag)
                XCTAssertFalse(row.rawNameHex.isEmpty, "\(artifact) entry \(row.entryIndex) should include central-directory raw filename hex")
                XCTAssertTrue(row.rawNameHex.count.isMultiple(of: 2), "\(artifact) entry \(row.entryIndex) hex should be byte-aligned")
                XCTAssertEqual(row.rawNameHex, row.rawNameHex.lowercased(), "\(artifact) entry \(row.entryIndex) raw_name_hex should be lowercase hex")
                XCTAssertTrue(row.rawNameHex.allSatisfy(\.isHexDigit), "\(artifact) entry \(row.entryIndex) raw_name_hex should contain only hex digits")
                XCTAssertEqual(row.hasUnicodePath, "no")
                XCTAssertEqual(row.unicodePathValid, "no")
                XCTAssertEqual(row.unicodePathHex, "none")
            }
        }
    }

    private func fixtureURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    }

    private func loadManifestRows() throws -> [ManifestRow] {
        let url = try XCTUnwrap(fixtureURL("filename_encoding_manifest.tsv"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(lines.first, ManifestRow.header)
        return try lines.dropFirst().map(ManifestRow.init(line:))
    }
}

private struct ArtifactExpectation {
    let filenameEncoding: String
    let expectedArchiveEncoding: String
    let utf8Flag: String
}

private struct ManifestRow {
    static let header = "artifact\tentry_index\tfilename_encoding\texpected_archive_encoding\tutf8_flag\thas_unicode_path\tunicode_path_valid\texpected_path\traw_name_hex\tunicode_path_hex"

    let artifact: String
    let entryIndex: Int
    let filenameEncoding: String
    let expectedArchiveEncoding: String
    let utf8Flag: String
    let hasUnicodePath: String
    let unicodePathValid: String
    let expectedPath: String
    let rawNameHex: String
    let unicodePathHex: String

    init(line: String) throws {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard columns.count == 10 else {
            throw ManifestError.invalidColumnCount(line: line, count: columns.count)
        }
        guard let entryIndex = Int(columns[1]) else {
            throw ManifestError.invalidEntryIndex(columns[1])
        }

        self.artifact = columns[0]
        self.entryIndex = entryIndex
        self.filenameEncoding = columns[2]
        self.expectedArchiveEncoding = columns[3]
        self.utf8Flag = columns[4]
        self.hasUnicodePath = columns[5]
        self.unicodePathValid = columns[6]
        self.expectedPath = columns[7]
        self.rawNameHex = columns[8]
        self.unicodePathHex = columns[9]
    }
}

private enum ManifestError: Error {
    case invalidColumnCount(line: String, count: Int)
    case invalidEntryIndex(String)
}
