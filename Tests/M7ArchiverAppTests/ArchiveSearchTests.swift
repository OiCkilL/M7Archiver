import XCTest
import ArchiveCore
import ArchivePresentation
@testable import M7ArchiverApp

final class ArchiveSearchTests: XCTestCase {
    private let search = ArchiveSearch()

    private func entries() -> [ArchiveEntry] {
        [
            ArchiveEntry(path: "README.txt", size: 5_000),
            ArchiveEntry(path: "Documents/draft.md", size: 1_200),
            ArchiveEntry(path: "Documents/notes/todo.txt", size: 200),
            ArchiveEntry(path: "Documents/notes/secret.txt", size: 320, isEncrypted: true),
            ArchiveEntry(path: "Photos/", isDirectory: true),
            ArchiveEntry(path: "Photos/IMG_001.png", size: 800_000),
            ArchiveEntry(path: "Photos/IMG_002.png", size: 750_000)
        ]
    }

    func testRowsAtRootListsTopLevelFoldersAndFiles() {
        let rows = search.rows(at: [], in: entries())
        let names = rows.map(\.name)
        XCTAssertTrue(names.contains("README.txt"))
        XCTAssertTrue(names.contains("Documents"))
        XCTAssertTrue(names.contains("Photos"))
        let docs = rows.first { $0.name == "Documents" }
        XCTAssertNotNil(docs)
        XCTAssertTrue(docs?.isDirectory ?? false)
    }

    func testRowsAtSubdirectoryShowsDirectChildrenOnly() {
        let rows = search.rows(at: ["Documents"], in: entries())
        let names = rows.map(\.name)
        XCTAssertTrue(names.contains("draft.md"))
        XCTAssertTrue(names.contains("notes"))
        XCTAssertFalse(names.contains("todo.txt"))
        XCTAssertFalse(names.contains("secret.txt"))
    }

    func testRowsDedupeRepeatedPaths() {
        var raw = entries()
        raw.append(ArchiveEntry(path: "README.txt", size: 5_000))
        let rows = search.rows(at: [], in: raw)
        XCTAssertEqual(rows.filter { $0.name == "README.txt" }.count, 1)
    }

    func testSearchIsRecursiveAndCaseInsensitive() {
        let rows = search.search(entries(), query: "TODO")
        XCTAssertEqual(rows.map(\.path), ["Documents/notes/todo.txt"])
    }

    func testSearchMatchesByPathSegment() {
        let rows = search.search(entries(), query: "notes")
        let paths = rows.map(\.path)
        XCTAssertTrue(paths.contains("Documents/notes/todo.txt"))
        XCTAssertTrue(paths.contains("Documents/notes/secret.txt"))
    }

    func testSearchEmptyQueryReturnsAllEntries() {
        let rows = search.search(entries(), query: "   ")
        XCTAssertEqual(rows.count, entries().count)
    }

    func testRowIDsAreStableAcrossInvocations() {
        let first = search.rows(at: [], in: entries())
        let second = search.rows(at: [], in: entries())
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }
}
