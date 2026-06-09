import AppKit
import XCTest
@testable import QuickLookPreviewExtension

@MainActor
final class PreviewViewControllerTests: XCTestCase {
    func testKnownZipContainerExtensionsUseZipFallbackFormat() {
        XCTAssertEqual(PreviewViewController.fallbackPreviewFormat(for: URL(fileURLWithPath: "/tmp/Test.ipa")), .zip)
        XCTAssertEqual(PreviewViewController.fallbackPreviewFormat(for: URL(fileURLWithPath: "/tmp/Test.apk")), .zip)
        XCTAssertEqual(PreviewViewController.fallbackPreviewFormat(for: URL(fileURLWithPath: "/tmp/Test.jar")), .zip)
        XCTAssertEqual(PreviewViewController.fallbackPreviewFormat(for: URL(fileURLWithPath: "/tmp/Test.cbz")), .zip)
        XCTAssertNil(PreviewViewController.fallbackPreviewFormat(for: URL(fileURLWithPath: "/tmp/Test.docx")))
        XCTAssertNil(PreviewViewController.fallbackPreviewFormat(for: URL(fileURLWithPath: "/tmp/Test.epub")))
        XCTAssertNil(PreviewViewController.fallbackPreviewFormat(for: URL(fileURLWithPath: "/tmp/Test.bin")))
    }

    func testHeaderUsesMetadataEntryCountInsteadOfSynthesizedTreeNodes() async throws {
        let archiveURL = try makeStoredZip(named: "nested.zip", path: "folder/readme.txt", contents: Data("hello".utf8))
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let controller = PreviewViewController()
        controller.loadView()

        try await controller.preparePreviewOfFile(at: archiveURL)

        let detail = try XCTUnwrap(textFields(in: controller.view).map(\.stringValue).first { $0.contains("uncompressed") })
        XCTAssertTrue(detail.hasPrefix("1 entry ·"), detail)

        let outline = try XCTUnwrap(outlineView(in: controller.view))
        XCTAssertEqual(rootChildCount(in: outline), 1)
    }

    func testUnknownFormatShowsExplicitUnsupportedErrorAndClearsPreviousRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = try makeStoredZip(in: directory, named: "valid.zip", path: "folder/readme.txt", contents: Data("hello".utf8))
        let unknownURL = directory.appendingPathComponent("payload")
        try Data("not an archive".utf8).write(to: unknownURL)

        let controller = PreviewViewController()
        controller.loadView()

        try await controller.preparePreviewOfFile(at: archiveURL)
        let outline = try XCTUnwrap(outlineView(in: controller.view))
        XCTAssertEqual(rootChildCount(in: outline), 1)

        try await controller.preparePreviewOfFile(at: unknownURL)

        let labels = textFields(in: controller.view).map(\.stringValue)
        XCTAssertTrue(labels.contains("Unable to Preview"), labels.joined(separator: " | "))
        XCTAssertTrue(labels.contains("Unsupported archive format."), labels.joined(separator: " | "))
        XCTAssertEqual(rootChildCount(in: outline), 0)
    }

    private func rootChildCount(in outline: NSOutlineView) -> Int? {
        outline.dataSource?.outlineView?(outline, numberOfChildrenOfItem: nil)
    }

    private func outlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView {
            return outline
        }
        for subview in view.subviews {
            if let outline = outlineView(in: subview) {
                return outline
            }
        }
        return nil
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        let current = (view as? NSTextField).map { [$0] } ?? []
        return current + view.subviews.flatMap(textFields(in:))
    }

    private func makeStoredZip(named name: String, path: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try makeStoredZip(in: directory, named: name, path: path, contents: contents)
    }

    private func makeStoredZip(in directory: URL, named name: String, path: String, contents: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Self.storedZip(path: path, contents: contents).write(to: url)
        return url
    }

    private static func storedZip(path: String, contents: Data) -> Data {
        let name = Data(path.utf8)
        let crc = crc32(contents)
        var data = Data()
        let localHeaderOffset = data.count

        data.appendUInt32LE(0x0403_4b50)
        data.appendUInt16LE(20)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt32LE(crc)
        data.appendUInt32LE(UInt32(contents.count))
        data.appendUInt32LE(UInt32(contents.count))
        data.appendUInt16LE(UInt16(name.count))
        data.appendUInt16LE(0)
        data.append(name)
        data.append(contents)

        let centralDirectoryOffset = data.count
        data.appendUInt32LE(0x0201_4b50)
        data.appendUInt16LE(20)
        data.appendUInt16LE(20)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt32LE(crc)
        data.appendUInt32LE(UInt32(contents.count))
        data.appendUInt32LE(UInt32(contents.count))
        data.appendUInt16LE(UInt16(name.count))
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt32LE(0)
        data.appendUInt32LE(UInt32(localHeaderOffset))
        data.append(name)

        let centralDirectorySize = data.count - centralDirectoryOffset
        data.appendUInt32LE(0x0605_4b50)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(UInt32(centralDirectorySize))
        data.appendUInt32LE(UInt32(centralDirectoryOffset))
        data.appendUInt16LE(0)

        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0xffff_ffff)) { crc, byte in
            var value = crc ^ UInt32(byte)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1
            }
            return value
        } ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
