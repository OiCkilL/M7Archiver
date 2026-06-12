import AppKit
import XCTest
import ArchiveCore
@testable import M7ArchiverApp

@MainActor
final class M7ArchiverAppDelegateQuickActionTests: XCTestCase {
    func testHandleValidatedAppURLAddToZipDoesNotCreateWindow() throws {
        let delegate = M7ArchiverAppDelegate()
        delegate.allowsTransientQuickActionTermination = false
        delegate.context.settings.revealInFinderAfterCreate = false

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("QuickActionRouteTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: file)
        let appUrl = AppUrl(action: .addToZip, files: [file], target: nil)
        let app = NSApplication.shared
        let beforeWindows = app.windows.count
        var calls: [(ArchiveFormat, [URL], URL?, ArchiveSettings)] = []
        delegate.quickCompressRunner = { format, sources, finderTarget, settings in
            calls.append((format, sources, finderTarget, settings))
        }

        delegate.handleValidatedAppURL(appUrl, context: delegate.context)
        waitUntil { calls.count == 1 }

        XCTAssertEqual(app.windows.count, beforeWindows)
        XCTAssertEqual(calls.first?.0, .zip)
        XCTAssertEqual(calls.first?.1, [file])

        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
    }

    func testHandleValidatedAppURLAddTo7zDoesNotCreateWindow() throws {
        let delegate = M7ArchiverAppDelegate()
        delegate.allowsTransientQuickActionTermination = false
        delegate.context.settings.revealInFinderAfterCreate = false

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("QuickActionRouteTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: file)
        let appUrl = AppUrl(action: .addTo7z, files: [file], target: nil)
        let app = NSApplication.shared
        let beforeWindows = app.windows.count
        var calls: [(ArchiveFormat, [URL], URL?, ArchiveSettings)] = []
        delegate.quickCompressRunner = { format, sources, finderTarget, settings in
            calls.append((format, sources, finderTarget, settings))
        }

        delegate.handleValidatedAppURL(appUrl, context: delegate.context)
        waitUntil { calls.count == 1 }

        XCTAssertEqual(app.windows.count, beforeWindows)
        XCTAssertEqual(calls.first?.0, .sevenZip)
        XCTAssertEqual(calls.first?.1, [file])

        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
    }

    func testApplicationOpenURLCreatesWindowForOpenArchiveWithoutInjectedWindowContext() throws {
        let delegate = M7ArchiverAppDelegate()
        delegate.allowsTransientQuickActionTermination = false
        delegate.context.settings.autoExtract = false

        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".m7archiver-open-route-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let archive = base.appendingPathComponent("sample.zip")
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: archive)
        let url = try XCTUnwrap(AppUrlParser.makeURL(action: .open, files: [archive]))
        let app = NSApplication.shared
        let beforeWindows = Set(app.windows.map { ObjectIdentifier($0) })

        delegate.application(app, open: [url])
        waitUntil(timeout: 2) {
            !self.visibleWindows(openedAfter: beforeWindows).isEmpty
        }

        XCTAssertFalse(visibleWindows(openedAfter: beforeWindows).isEmpty)

        addTeardownBlock { [weak self] in
            self?.closeWindows(openedAfter: beforeWindows)
            try? FileManager.default.removeItem(at: base)
        }
    }

    func testApplicationOpenURLShowsAddToArchiveDialogWithoutInjectedWindowContext() throws {
        let delegate = M7ArchiverAppDelegate()
        delegate.allowsTransientQuickActionTermination = false

        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".m7archiver-add-route-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: file)
        let url = try XCTUnwrap(AppUrlParser.makeURL(action: .addToArchive, files: [file], target: base))
        let app = NSApplication.shared
        let beforeWindows = Set(app.windows.map { ObjectIdentifier($0) })

        delegate.application(app, open: [url])
        waitUntil(timeout: 2) {
            self.visibleWindows(openedAfter: beforeWindows).contains { $0.title == "Compress Archive" }
        }

        XCTAssertTrue(visibleWindows(openedAfter: beforeWindows).contains { $0.title == "Compress Archive" })

        addTeardownBlock { [weak self] in
            self?.closeWindows(openedAfter: beforeWindows)
            try? FileManager.default.removeItem(at: base)
        }
    }

    func testApplicationReopenCreatesMainWindowWhenNoWindowsAreVisible() {
        let delegate = M7ArchiverAppDelegate()
        let app = NSApplication.shared
        let beforeWindows = Set(app.windows.map { ObjectIdentifier($0) })

        let shouldContinue = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)

        XCTAssertFalse(shouldContinue)
        XCTAssertFalse(visibleWindows(openedAfter: beforeWindows).isEmpty)

        addTeardownBlock { [weak self] in
            self?.closeWindows(openedAfter: beforeWindows)
        }
    }

    func testApplicationOpenURLRoutesQuickActionWithoutInjectedWindowContext() throws {
        let delegate = M7ArchiverAppDelegate()
        delegate.allowsTransientQuickActionTermination = false
        delegate.context.settings.revealInFinderAfterCreate = false

        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".m7archiver-quick-action-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: file)
        let url = try XCTUnwrap(AppUrlParser.makeURL(action: .addToZip, files: [file]))
        let app = NSApplication.shared
        let beforeWindows = app.windows.count
        var calls: [(ArchiveFormat, [URL], URL?, ArchiveSettings)] = []
        delegate.quickCompressRunner = { format, sources, finderTarget, settings in
            calls.append((format, sources, finderTarget, settings))
        }

        delegate.application(app, open: [url])
        waitUntil { calls.count == 1 }

        XCTAssertEqual(app.windows.count, beforeWindows)
        XCTAssertEqual(calls.first?.0, .zip)
        XCTAssertEqual(calls.first?.1, [file])

        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func waitUntil(timeout: TimeInterval = 1, _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func visibleWindows(openedAfter beforeWindows: Set<ObjectIdentifier>) -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !beforeWindows.contains(ObjectIdentifier($0)) }
    }

    private func closeWindows(openedAfter beforeWindows: Set<ObjectIdentifier>) {
        for window in visibleWindows(openedAfter: beforeWindows) {
            window.close()
        }
    }
}
