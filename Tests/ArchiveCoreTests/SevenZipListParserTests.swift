import XCTest
@testable import ArchiveCore

final class SevenZipListParserTests: XCTestCase {
    func testParsesArchiveBlockAndEntries() {
        let raw = """

        7-Zip 23.01 ...

        Listing archive: foo.7z

        --
        Path = foo.7z
        Type = 7z
        Physical Size = 234
        Headers Size = 100
        Method = LZMA2:23
        Solid = -
        Blocks = 1
        Volumes = 1

        ----------
        Path = readme.txt
        Folder = -
        Size = 100
        Packed Size = 50
        Modified = 2024-01-02 03:04:05
        Attributes = A
        Encrypted = -
        Method = LZMA2:23

        Path = src
        Folder = +
        Size = 0
        Packed Size = 0
        Modified = 2024-01-02 03:04:05
        Attributes = D
        Encrypted = -

        Path = src/main.swift
        Folder = -
        Size = 200
        Packed Size = 110
        Modified = 2024-02-03 04:05:06
        Attributes = A
        Encrypted = +
        Method = LZMA2:23

        """

        let parsed = SevenZipListParser.parse(raw)
        XCTAssertEqual(parsed.archive["Type"], "7z")
        XCTAssertEqual(parsed.archive["Volumes"], "1")

        XCTAssertEqual(parsed.entries.count, 3)

        let readme = parsed.entries[0]
        XCTAssertEqual(readme.path, "readme.txt")
        XCTAssertEqual(readme.size, 100)
        XCTAssertEqual(readme.packedSize, 50)
        XCTAssertFalse(readme.isDirectory)
        XCTAssertFalse(readme.isEncrypted)
        XCTAssertEqual(readme.method, "LZMA2:23")
        XCTAssertNotNil(readme.modifiedAt)

        let directory = parsed.entries[1]
        XCTAssertEqual(directory.path, "src")
        XCTAssertTrue(directory.isDirectory)

        let encrypted = parsed.entries[2]
        XCTAssertEqual(encrypted.path, "src/main.swift")
        XCTAssertTrue(encrypted.isEncrypted)
    }

    func testHandlesSubsecondModifiedTimestamps() {
        let raw = """
        --
        Path = foo.7z
        Type = 7z

        ----------
        Path = file.txt
        Size = 1
        Modified = 2024-05-06 07:08:09.1234567
        Attributes = A

        """
        let parsed = SevenZipListParser.parse(raw)
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertNotNil(parsed.entries[0].modifiedAt)
    }

    func testParsesEntryOnlyOutput() {
        // `7zz l -slt -ba` skips the header banner and archive metadata.
        let raw = """
        Path = a.txt
        Size = 10
        Packed Size = 5
        Modified = 2024-01-01 00:00:00
        Attributes = A

        Path = b.txt
        Size = 20
        Packed Size = 12
        Modified = 2024-01-01 00:00:00
        Attributes = A

        """
        let parsed = SevenZipListParser.parse(raw)
        XCTAssertTrue(parsed.archive.isEmpty)
        XCTAssertEqual(parsed.entries.map(\.path), ["a.txt", "b.txt"])
    }

    func testReturnsEmptyWhenOutputIsEmpty() {
        let parsed = SevenZipListParser.parse("")
        XCTAssertTrue(parsed.archive.isEmpty)
        XCTAssertTrue(parsed.entries.isEmpty)
    }
}
