import AppKit
import XCTest
import ArchiveCore
@testable import M7ArchiverApp

@MainActor
final class M7ArchiverAppDelegateQuickActionTests: XCTestCase {
    func testHandleValidatedAppURLAddToZipDoesNotCreateWindow() throws {
        let delegate = M7ArchiverAppDelegate()
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

    func testApplicationOpenURLRoutesQuickActionWithoutInjectedWindowContext() throws {
        let delegate = M7ArchiverAppDelegate()
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

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
