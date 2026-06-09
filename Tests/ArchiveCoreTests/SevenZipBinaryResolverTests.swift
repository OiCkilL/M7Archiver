import XCTest
@testable import ArchiveCore

final class SevenZipBinaryResolverTests: XCTestCase {
    func testResolveReturnsFirstExecutableCandidate() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let stub = temp.appendingPathComponent("7zz")
        FileManager.default.createFile(atPath: stub.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let result = SevenZipBinaryResolver.resolve(
            candidates: ["/no/such/path", stub.path],
            bundledLocations: [],
            allowSystemFallback: true
        )
        XCTAssertEqual(result?.path, stub.path)
    }

    func testResolveReturnsNilWhenNoCandidateExecutable() {
        let result = SevenZipBinaryResolver.resolve(
            candidates: ["/no/such/path/here", "/also/missing"],
            bundledLocations: []
        )
        XCTAssertNil(result)
    }

    func testResolveIgnoresSystemFallbackUnlessExplicitlyAllowed() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let systemStub = temp.appendingPathComponent("system-7zz")
        FileManager.default.createFile(atPath: systemStub.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemStub.path)

        let result = SevenZipBinaryResolver.resolve(
            candidates: [systemStub.path],
            bundledLocations: []
        )
        XCTAssertNil(result)
    }

    func testBundledLocationOverridesSystemCandidates() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let bundled = temp.appendingPathComponent("vendored-7zz")
        FileManager.default.createFile(atPath: bundled.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)

        let systemStub = temp.appendingPathComponent("system-7zz")
        FileManager.default.createFile(atPath: systemStub.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemStub.path)

        let result = SevenZipBinaryResolver.resolve(
            candidates: [systemStub.path],
            bundledLocations: [bundled],
            allowSystemFallback: true
        )
        XCTAssertEqual(result?.path, bundled.path)
    }

    func testDefaultURLFallsBackToVendoredPathInsteadOfSystemCandidate() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let systemStub = temp.appendingPathComponent("system-7zz")
        FileManager.default.createFile(atPath: systemStub.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemStub.path)

        let url = SevenZipBinaryResolver.defaultURL(
            candidates: [systemStub.path],
            bundledLocations: [],
            fileManager: FileManager.default
        )

        XCTAssertTrue(url.path.hasSuffix(SevenZipBinaryResolver.projectRelativePaths[0]))
        XCTAssertNotEqual(url.path, systemStub.path)
    }
}
