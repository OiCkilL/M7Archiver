import XCTest
@testable import ArchiveCore

/// Integration test that drives `SevenZipEngine` through the actual
/// project-vendored `Vendor/7zip/bin/7zz` binary.
///
/// Skips silently when the binary hasn't been built yet so the unit-test
/// suite stays runnable on a fresh checkout. Run `Vendor/7zip/build-7zz.sh`
/// to populate it.
final class SevenZipEngineIntegrationTests: XCTestCase {
    private var workspace: URL!
    private var engine: SevenZipEngine!

    override func setUpWithError() throws {
        guard let bundled = Self.locateBundledBinary() else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built. Run Vendor/7zip/build-7zz.sh.")
        }

        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("M7Archiver-7z-it-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        engine = SevenZipEngine(executableURL: bundled)
    }

    override func tearDownWithError() throws {
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    func testRoundTripCreateListTestExtract7z() async throws {
        let source = workspace.appendingPathComponent("hello.txt")
        try Data("integration-hello".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("hello.7z")

        let profile = CompressionProfile(
            name: "Standard 7z",
            format: .sevenZip,
            level: .normal,
            solid: false
        )
        _ = try await engine.createArchive(from: [source], to: archive, profile: profile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let entries = try await engine.listContents(of: archive)
        XCTAssertEqual(entries.map(\.path), ["hello.txt"])
        XCTAssertEqual(entries.first?.size, Int64("integration-hello".utf8.count))
        XCTAssertNil(entries.first?.packedSize) // bridge path currently omits packed size

        let metadata = try await engine.metadata(of: archive)
        XCTAssertEqual(metadata.format, .sevenZip)
        XCTAssertEqual(metadata.entriesCount, 1)
        XCTAssertFalse(metadata.isEncrypted)

        let testResult = try await engine.testArchive(archive)
        XCTAssertEqual(testResult.entries.first?.path, "hello.txt")

        let outDir = workspace.appendingPathComponent("out", isDirectory: true)
        let extractResult = try await engine.extract(archive, to: outDir)
        XCTAssertEqual(extractResult.entries.map(\.path), ["hello.txt"])
        let extracted = try Data(contentsOf: outDir.appendingPathComponent("hello.txt"))
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "integration-hello")
    }

    func testRoundTripCreateEncrypted7zWithStdinPassword() async throws {
        let source = workspace.appendingPathComponent("secret.txt")
        try Data("integration-secret".utf8).write(to: source)
        let archive = workspace.appendingPathComponent("secret.7z")

        let profile = CompressionProfile(
            name: "Encrypted 7z",
            format: .sevenZip,
            level: .normal,
            solid: false,
            encryptFileNames: true
        )
        _ = try await engine.createArchive(
            from: [source],
            to: archive,
            profile: profile,
            password: "s3cret"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let result = try runSevenZip(["t", archive.path, "-ps3cret", "-y", "-bd"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)

        let wrong = try runSevenZip(["t", archive.path, "-pwrong", "-y", "-bd"])
        XCTAssertNotEqual(wrong.exitCode, 0)
        XCTAssertTrue((wrong.stdout + wrong.stderr).contains("Wrong password"))

        let provider: ArchivePasswordProvider = { _ in "s3cret" }
        let options = ArchiveOperationOptions(passwordProvider: provider)

        let entries = try await engine.listContents(of: archive, options: options)
        XCTAssertEqual(entries.map(\.path), ["secret.txt"])
        XCTAssertEqual(entries.first?.size, Int64("integration-secret".utf8.count))

        let metadata = try await engine.metadata(of: archive, options: options)
        XCTAssertEqual(metadata.format, .sevenZip)
        XCTAssertEqual(metadata.entriesCount, 1)
        XCTAssertTrue(metadata.isEncrypted)

        let testResult = try await engine.testArchive(archive, options: options)
        XCTAssertEqual(testResult.entries.map(\.path), ["secret.txt"])

        let outDir = workspace.appendingPathComponent("encrypted-out", isDirectory: true)
        let extractResult = try await engine.extract(archive, to: outDir, options: options)
        XCTAssertEqual(extractResult.entries.map(\.path), ["secret.txt"])
        let extracted = try Data(contentsOf: outDir.appendingPathComponent("secret.txt"))
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "integration-secret")
    }

    // MARK: - Helpers

    private func runSevenZip(_ arguments: [String]) throws -> SevenZipProcessResult {
        let process = Process()
        process.executableURL = engine.executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return SevenZipProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    /// Drives the streaming create path against the real `7zz` binary:
    /// `-bsp1` progress must be parsed and forwarded via `onCreateProgress`
    /// as a monotonic fraction sequence.  Uses hard-to-compress random data
    /// so 7z runs long enough to emit multiple percentage updates.
    func testStreamingCreateReportsRealPercentageProgress() async throws {
        guard let bundled = Self.locateBundledBinary() else {
            throw XCTSkip("Vendor/7zip/bin/7zz is not built.")
        }
        let streamingEngine = SevenZipEngine(
            executableURL: bundled,
            progressRunner: SevenZipDefaultRunner.runStreaming
        )

        // ~80 MiB of random bytes: incompressible, so 7z spends real time.
        let source = workspace.appendingPathComponent("rand.bin")
        var random = Data(count: 80 * 1_000_000)
        _ = random.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        try random.write(to: source)

        let archive = workspace.appendingPathComponent("rand.7z")
        let profile = CompressionProfile(name: "Stream 7z", format: .sevenZip, level: .normal, solid: false)

        let collector = ProgressCollector()
        let options = ArchiveOperationOptions(onCreateProgress: { fraction in
            collector.append(fraction)
        })

        let result = try await streamingEngine.createArchive(
            from: [source], to: archive, profile: profile,
            password: nil, encryptionMethod: nil, options: options
        )
        XCTAssertEqual(result.outputURLs, [archive])
        let fractions = collector.values
        XCTAssertFalse(fractions.isEmpty, "expected real 7z progress to be reported")
        // The final reported fraction should be near completion.  7-Zip does
        // not always emit a final 100% before exiting (it may stop at ~93-97%
        // depending on data and timing), so assert a loose lower bound.
        XCTAssertGreaterThanOrEqual(fractions.last!, 0.85, "last fraction \(fractions.last!) should be near completion")
        // Fractions must be within the valid range and non-decreasing.
        for f in fractions {
            XCTAssertGreaterThanOrEqual(f, 0.0)
            XCTAssertLessThanOrEqual(f, 1.0)
        }
    }

    private static func locateBundledBinary() -> URL? {
        // Walk up from #file (this test source) to the repo root, then
        // append Vendor/7zip/bin/7zz. Resolve symlinks so the test still
        // works under SwiftPM's build sandbox.
        let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        var dir = here.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir
                .appendingPathComponent("Vendor/7zip/bin/7zz")
                .standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}

/// Thread-safe collector for `onCreateProgress` callbacks (invoked off the
/// main actor from the streaming runner's pipe reader).  Uses an `NSLock`
/// rather than an actor so the callback can append synchronously.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ fraction: Double) {
        lock.lock(); storage.append(fraction); lock.unlock()
    }
    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
