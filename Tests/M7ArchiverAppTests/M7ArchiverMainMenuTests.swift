import AppKit
import XCTest
@testable import M7ArchiverApp

final class M7ArchiverMainMenuTests: XCTestCase {
    @MainActor
    func testApplicationLaunchMakesSwiftRunExecutableARegularAppWithMainMenu() {
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        let originalMainMenu = app.mainMenu
        let originalWindowsMenu = app.windowsMenu
        defer {
            app.mainMenu = originalMainMenu
            app.windowsMenu = originalWindowsMenu
            app.setActivationPolicy(originalPolicy)
        }

        _ = app.setActivationPolicy(.prohibited)

        let delegate = M7ArchiverAppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: app)
        )

        XCTAssertEqual(app.activationPolicy(), .regular)
        XCTAssertEqual(app.mainMenu?.items.count, 5)
        XCTAssertEqual(app.mainMenu?.items[1].submenu?.title, "File")
        XCTAssertEqual(app.mainMenu?.items[2].submenu?.title, "Edit")
        XCTAssertEqual(app.mainMenu?.items[3].submenu?.title, "Window")
        XCTAssertEqual(app.mainMenu?.items[4].submenu?.title, "Help")
        XCTAssertEqual(app.windowsMenu?.title, "Window")
    }

    @MainActor
    func testOpenRecentClearMenuIsHandledByAppDelegate() throws {
        let app = NSApplication.shared
        let originalMainMenu = app.mainMenu
        let originalWindowsMenu = app.windowsMenu
        defer {
            app.mainMenu = originalMainMenu
            app.windowsMenu = originalWindowsMenu
        }

        let delegate = M7ArchiverAppDelegate()
        delegate.ensureMainMenu()

        let fileMenu = try XCTUnwrap(app.mainMenu?.items[1].submenu)
        let openRecentMenu = try XCTUnwrap(fileMenu.items.first { $0.title == "Open Recent" }?.submenu)
        let clearItem = try XCTUnwrap(openRecentMenu.items.last)

        XCTAssertTrue(clearItem.target === delegate)
        XCTAssertEqual(clearItem.action, NSSelectorFromString("handleClearRecent:"))
    }
}
