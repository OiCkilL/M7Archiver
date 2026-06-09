import XCTest
@testable import M7ArchiverApp

final class SavedPasswordsStoreTests: XCTestCase {
    @MainActor
    func testSaveLookupRoundTripUsesStandardizedPath() {
        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        let url = URL(fileURLWithPath: "/Users/evan/Archives/secret.7z")

        store.save(password: "hunter2", for: url)

        XCTAssertEqual(store.lookup(for: url), "hunter2")
        XCTAssertEqual(store.lookup(for: URL(fileURLWithPath: "/Users/evan/Archives/./secret.7z")), "hunter2")
    }

    @MainActor
    func testLookupForUnknownArchiveReturnsNil() {
        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        let url = URL(fileURLWithPath: "/Users/evan/Archives/missing.7z")
        XCTAssertNil(store.lookup(for: url))
    }

    @MainActor
    func testSaveOverwritesExistingPassword() {
        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        let url = URL(fileURLWithPath: "/tmp/foo.zip")

        store.save(password: "old", for: url)
        store.save(password: "new", for: url)

        XCTAssertEqual(store.lookup(for: url), "new")
        XCTAssertEqual(store.entries.count, 1)
    }

    @MainActor
    func testEntriesAreSortedByMostRecentlySavedFirst() async throws {
        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())

        store.save(password: "a", for: URL(fileURLWithPath: "/tmp/a.zip"))
        try await Task.sleep(nanoseconds: 10_000_000)
        store.save(password: "b", for: URL(fileURLWithPath: "/tmp/b.zip"))
        try await Task.sleep(nanoseconds: 10_000_000)
        store.save(password: "c", for: URL(fileURLWithPath: "/tmp/c.zip"))

        XCTAssertEqual(store.entries.map(\.path), ["/tmp/c.zip", "/tmp/b.zip", "/tmp/a.zip"])
    }

    @MainActor
    func testDeleteRemovesEntryAndDropsLookup() {
        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        let url = URL(fileURLWithPath: "/tmp/foo.zip")
        store.save(password: "x", for: url)

        store.delete(for: url)

        XCTAssertNil(store.lookup(for: url))
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor
    func testDeleteByEntryRemovesItToo() {
        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        let url = URL(fileURLWithPath: "/tmp/foo.zip")
        store.save(password: "x", for: url)
        let entry = store.entries.first!

        store.delete(entry)

        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor
    func testClearAllEmptiesEntries() {
        let store = SavedPasswordsStore(backend: InMemorySavedPasswordsBackend())
        store.save(password: "1", for: URL(fileURLWithPath: "/tmp/a.zip"))
        store.save(password: "2", for: URL(fileURLWithPath: "/tmp/b.zip"))

        store.clearAll()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.lookup(for: URL(fileURLWithPath: "/tmp/a.zip")))
    }
}
