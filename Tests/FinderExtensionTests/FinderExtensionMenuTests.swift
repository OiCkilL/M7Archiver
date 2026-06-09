import AppKit
import FinderSync
import XCTest
@testable import FinderExtension

final class FinderExtensionMenuTests: XCTestCase {
    @MainActor
    func testArchiveSelectionShowsArchiveActionsOnly() throws {
        let sync = M7ArchiverFinderSync()
        let menu = sync.makeMenu(
            for: .contextualMenuForItems,
            selected: [URL(fileURLWithPath: "/tmp/example.zip")]
        )

        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.items[0].title, "M7Archiver")

        let submenu = try XCTUnwrap(menu.items[0].submenu)
        XCTAssertEqual(enabledTitles(in: submenu), [
            "Open in M7Archiver",
            "Extract Files…",
            "Extract Here",
            "Extract to \"example\"",
            "Test Archive"
        ])
        XCTAssertFalse(submenu.items.contains { $0.isSeparatorItem })
        XCTAssertFalse(submenu.items.contains { $0.title.isEmpty })
        XCTAssertFalse(submenu.items.contains { $0.view != nil })
        XCTAssertEqual(symbolNames(in: submenu), [
            "Open in M7Archiver": "folder",
            "Extract Files…": "doc.badge.arrow.up",
            "Extract Here": "shippingbox.fill",
            "Extract to \"example\"": "shippingbox.fill",
            "Test Archive": "shield.checkered"
        ])
    }

    @MainActor
    func testToolbarMenuShowsActionsDirectly() {
        let sync = M7ArchiverFinderSync()
        let menu = sync.makeMenu(
            for: .toolbarItemMenu,
            selected: [URL(fileURLWithPath: "/tmp/example.zip")]
        )

        XCTAssertEqual(menu.title, "M7Archiver")
        XCTAssertEqual(menu.items.first?.title, "Open in M7Archiver")
    }

    @MainActor
    func testGeneralFileSelectionShowsCompressionActionsOnly() {
        let sync = M7ArchiverFinderSync()
        let menu = sync.makeMenu(
            for: .contextualMenuForItems,
            selected: [URL(fileURLWithPath: "/tmp/report.pdf")]
        )

        let submenu = menu.items[0].submenu!
        XCTAssertEqual(enabledTitles(in: submenu), [
            "Add to Archive…",
            "Compress in ZIP",
            "Compress in 7z"
        ])
        XCTAssertEqual(symbolNames(in: submenu), [
            "Add to Archive…": "document.badge.plus",
            "Compress in ZIP": "doc.zipper",
            "Compress in 7z": "archivebox"
        ])
        XCTAssertEqual(submenu.items[1].action, #selector(M7ArchiverFinderSync.addToZip(_:)))
        XCTAssertEqual(submenu.items[2].action, #selector(M7ArchiverFinderSync.addTo7z(_:)))
    }

    @MainActor
    func testFolderSelectionShowsCompressionActionsOnly() {
        let sync = M7ArchiverFinderSync()
        let menu = sync.makeMenu(
            for: .contextualMenuForItems,
            selected: [URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)]
        )

        let submenu = menu.items[0].submenu!
        XCTAssertEqual(enabledTitles(in: submenu), [
            "Add to Archive…",
            "Compress in ZIP",
            "Compress in 7z"
        ])
    }

    @MainActor
    func testFolderWithArchiveLikeNameShowsCompressionActionsOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sync = M7ArchiverFinderSync()
        let menu = sync.makeMenu(
            for: .contextualMenuForItems,
            selected: [URL(fileURLWithPath: directory.path)]
        )

        let submenu = menu.items[0].submenu!
        XCTAssertEqual(enabledTitles(in: submenu), [
            "Add to Archive…",
            "Compress in ZIP",
            "Compress in 7z"
        ])
    }

    @MainActor
    func testMixedArchiveAndGeneralSelectionShowsCompressionActionsOnly() {
        let sync = M7ArchiverFinderSync()
        let menu = sync.makeMenu(
            for: .contextualMenuForItems,
            selected: [
                URL(fileURLWithPath: "/tmp/example.zip"),
                URL(fileURLWithPath: "/tmp/report.pdf")
            ]
        )

        let submenu = menu.items[0].submenu!
        XCTAssertEqual(enabledTitles(in: submenu), [
            "Add to Archive…",
            "Compress in ZIP",
            "Compress in 7z"
        ])
    }

    func testMenuCanBeBuiltOffMainThread() {
        let expectation = expectation(description: "menu built")
        DispatchQueue.global().async {
            let sync = M7ArchiverFinderSync()
            let menu = sync.makeMenu(
                for: .contextualMenuForItems,
                selected: [URL(fileURLWithPath: "/tmp/example.zip")]
            )
            XCTAssertEqual(menu.items.count, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    private func enabledTitles(in menu: NSMenu) -> [String] {
        menu.items
            .filter { !$0.isSeparatorItem }
            .filter(\.isEnabled)
            .map(\.title)
    }

    private func symbolNames(in menu: NSMenu) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: menu.items
                .filter(\.isEnabled)
                .map { item in
                    XCTAssertNotNil(item.image, "\(item.title) should have a menu icon")
                    return (item.title, item.representedObject as? String ?? "")
                }
        )
    }
}
